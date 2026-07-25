"""Executor-side implementations of isolated utility tasks."""

from __future__ import annotations

import json
import subprocess
import threading
from dataclasses import asdict
from typing import Any, Callable, Mapping

from .execution import (
    AnsibleRunner,
    ExecutionError,
    KnownHostsPolicy,
    MAX_DIAGNOSTIC_BYTES,
    SecretRedactor,
    SyntaxChecker,
)
from .target_policy import ApprovedTarget, TargetPolicyError


MAX_TARGETS = 1_000
MAX_HOST_KEY_CANDIDATES = 1_000


class TaskCanceled(ExecutionError):
    pass


class HostKeyScanner:
    def __init__(
        self,
        *,
        executable: str = "/usr/bin/ssh-keyscan",
        run: Callable = subprocess.run,
        timeout_seconds: int = 10,
    ) -> None:
        self.executable = executable
        self.run = run
        self.timeout_seconds = timeout_seconds

    def scan(self, targets: list[ApprovedTarget]) -> list[dict[str, Any]]:
        candidates = []
        for target in targets:
            completed = self.run(
                [self.executable, "-T", str(self.timeout_seconds), "-p", str(target.port), target.address],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds + 2,
                check=False,
                start_new_session=True,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
            )
            if completed.returncode not in {0, 1}:
                raise ExecutionError(f"host-key scan failed for {target.host}")
            target_candidates = self._candidates(target, completed.stdout)
            if not target_candidates:
                raise ExecutionError(f"host-key scan returned no keys for {target.host}")
            candidates.extend(target_candidates)
            if len(candidates) > MAX_HOST_KEY_CANDIDATES:
                raise ExecutionError("host-key scan returned too many candidates")
        return candidates

    @staticmethod
    def _candidates(target: ApprovedTarget, stdout: str) -> list[dict[str, Any]]:
        candidates = []
        host_field = target.host if target.port == 22 else f"[{target.host}]:{target.port}"
        for raw_line in stdout.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) < 3:
                continue
            known_hosts_line = " ".join([host_field, fields[1], fields[2]])
            try:
                fingerprint = KnownHostsPolicy.fingerprint(known_hosts_line)
            except ExecutionError:
                continue
            candidates.append({
                "host": target.host,
                "port": target.port,
                "known_hosts_line": known_hosts_line,
                "fingerprint": fingerprint,
            })
        return candidates


class TaskProcessor:
    def __init__(
        self,
        *,
        client,
        target_policy,
        workspace,
        scanner: HostKeyScanner | None = None,
        syntax_checker: Callable | None = None,
        runner: Callable | None = None,
        cancel_event: threading.Event | None = None,
    ) -> None:
        self.client = client
        self.target_policy = target_policy
        self.workspace = workspace
        self.scanner = scanner or HostKeyScanner()
        self.syntax_checker = syntax_checker or SyntaxChecker()
        self.runner = runner or AnsibleRunner()
        self.cancel_event = cancel_event or threading.Event()

    def process(self, claim: Mapping[str, Any]) -> None:
        task_id = int(claim["id"])
        lease = str(claim["lease"])
        kind = str(claim.get("kind", ""))
        payload = _mapping(claim.get("payload"))
        try:
            targets = self._approve_targets(payload)
            if kind == "host_key_scan":
                output = {"candidates": self.scanner.scan(targets)}
            elif kind == "syntax_check":
                output = self._syntax(payload, targets)
            elif kind == "connectivity_test":
                output = self._connectivity(payload, targets)
            else:
                raise ExecutionError("unsupported executor task kind")
            self.client.finish_task(task_id, lease, {"status": "succeeded", "result": output})
        except TaskCanceled:
            self.client.finish_task(
                task_id,
                lease,
                {"status": "canceled", "result": {}, "error_code": "canceled"},
            )
        except (ExecutionError, TargetPolicyError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
            redactor = SecretRedactor(_credential_values(payload))
            detail = redactor.redact(str(error)).encode("utf-8")[:MAX_DIAGNOSTIC_BYTES].decode("utf-8", errors="ignore")
            self.client.finish_task(
                task_id,
                lease,
                {"status": "failed", "result": {}, "error_code": "executor_rejected", "error_detail": detail},
            )

    def _syntax(self, payload: Mapping[str, Any], targets: list[ApprovedTarget]) -> dict[str, Any]:
        with self.workspace.materialize(payload, [asdict(target) for target in targets]) as materialized:
            options = _mapping(payload.get("options"))
            result = self.syntax_checker(
                materialized,
                timeout_seconds=int(options.get("timeout_seconds", 300)),
                cancel_event=self.cancel_event,
            )
        errors = [] if result.valid else [result.output[:MAX_DIAGNOSTIC_BYTES]]
        if result.canceled:
            raise TaskCanceled("syntax check was canceled")
        return {"valid": result.valid, "errors": errors}

    def _connectivity(self, payload: Mapping[str, Any], targets: list[ApprovedTarget]) -> dict[str, Any]:
        KnownHostsPolicy.validate(str(payload.get("known_hosts", "")), targets)
        credential = dict(_mapping(payload.get("credential")))
        execution_payload = {
            "playbook_yaml": json.dumps([{
                "name": "Hunter connectivity test",
                "hosts": "all",
                "gather_facts": False,
                "tasks": [{"name": "Ansible ping", "ansible.builtin.ping": {}}],
            }]),
            "inventory_yaml": json.dumps({"all": {"hosts": {target.host: {} for target in targets}}}),
            "known_hosts": payload.get("known_hosts", ""),
            "variables": {},
            "secrets": credential,
            "options": {"host_limit": None, "check_mode": False, "timeout_seconds": 60},
        }
        statuses = {target.host: {"host": target.host, "status": "unknown"} for target in targets}

        def capture(event):
            host = event.get("host")
            if host not in statuses:
                return
            if event.get("event_type") == "runner_on_ok":
                statuses[host] = {"host": host, "status": "reachable"}
            elif event.get("event_type") == "runner_on_unreachable":
                statuses[host] = {"host": host, "status": "unreachable", "error_code": "unreachable"}
            elif event.get("event_type") == "runner_on_failed":
                statuses[host] = {"host": host, "status": "failed", "error_code": "ansible_failed"}

        with self.workspace.materialize(execution_payload, [asdict(target) for target in targets]) as materialized:
            result = self.runner(
                materialized,
                execution_payload,
                cancel_event=self.cancel_event,
                event_handler=capture,
            )
        if result.status == "canceled":
            raise TaskCanceled("connectivity test was canceled")
        if result.status == "failed":
            statuses = {
                host: value if value["status"] != "unknown" else {
                    "host": host, "status": "failed", "error_code": "runner_failed"
                }
                for host, value in statuses.items()
            }
        return {"hosts": list(statuses.values())}

    def _approve_targets(self, payload: Mapping[str, Any]) -> list[ApprovedTarget]:
        raw_targets = payload.get("targets")
        if not isinstance(raw_targets, list) or not raw_targets:
            raise ExecutionError("executor task has no targets")
        if len(raw_targets) > MAX_TARGETS:
            raise ExecutionError("executor task has too many targets")
        return [self.target_policy.approve(_mapping(target)) for target in raw_targets]


def _mapping(value: object) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _credential_values(payload: Mapping[str, Any]) -> list[object]:
    credential = _mapping(payload.get("credential"))
    return [value for value in credential.values() if value is not None]
