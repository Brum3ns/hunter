"""Secure execution primitives and playbook-run processing."""

from __future__ import annotations

import base64
import hashlib
import multiprocessing
import os
import queue
import signal
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping

from .target_policy import ApprovedTarget, TargetPolicyError


FILTERED = "[FILTERED]"
MAX_DIAGNOSTIC_BYTES = 4096
MAX_TARGETS = 1_000


class ExecutionError(RuntimeError):
    pass


class KnownHostsError(ExecutionError):
    pass


class SecretRedactor:
    def __init__(self, secrets: Iterable[object]) -> None:
        self.secrets = tuple(sorted({str(value) for value in secrets if value is not None and str(value)}, key=len, reverse=True))

    def redact(self, value: Any) -> Any:
        if isinstance(value, str):
            for secret in self.secrets:
                value = value.replace(secret, FILTERED)
            return value
        if isinstance(value, Mapping):
            return {
                FILTERED if str(key) in self.secrets else key: self.redact(child)
                for key, child in value.items()
            }
        if isinstance(value, list):
            return [self.redact(child) for child in value]
        if isinstance(value, tuple):
            return tuple(self.redact(child) for child in value)
        return value


class KnownHostsPolicy:
    @classmethod
    def validate(cls, known_hosts: str, targets: Iterable[ApprovedTarget]) -> None:
        lines = [line.strip() for line in known_hosts.splitlines() if line.strip() and not line.lstrip().startswith("#")]
        if not lines:
            raise KnownHostsError("approved known-host entries are required")
        parsed = []
        for line in lines:
            fields = line.split()
            if len(fields) < 3 or not fields[1].startswith(("ssh-", "ecdsa-")):
                raise KnownHostsError("known-host entry is malformed")
            cls.fingerprint(line)
            parsed.append(fields[0].split(","))

        for target in targets:
            expected = cls._host_tokens(target)
            if not any(expected.intersection(tokens) for tokens in parsed):
                raise KnownHostsError(f"no approved host key exists for {target.host}")

    @staticmethod
    def fingerprint(line: str) -> str:
        try:
            encoded = line.split()[2]
            key = base64.b64decode(encoded, validate=True)
        except (IndexError, ValueError) as error:
            raise KnownHostsError("known-host key is malformed") from error
        digest = base64.b64encode(hashlib.sha256(key).digest()).decode("ascii").rstrip("=")
        return f"SHA256:{digest}"

    @staticmethod
    def _host_tokens(target: ApprovedTarget) -> set[str]:
        names = {target.host, target.address}
        if target.port == 22:
            return names | {f"[{name}]:22" for name in names}
        return {f"[{name}]:{target.port}" for name in names}


@dataclass(frozen=True)
class SyntaxResult:
    valid: bool
    exit_status: int | None
    output: str
    canceled: bool = False
    timed_out: bool = False


class SyntaxChecker:
    def __init__(
        self,
        *,
        executable: str = "/usr/local/bin/ansible-playbook",
        popen: Callable = subprocess.Popen,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        cancel_grace_seconds: float = 10.0,
    ) -> None:
        self.executable = executable
        self.popen = popen
        self.monotonic = monotonic
        self.sleep = sleep
        self.cancel_grace_seconds = cancel_grace_seconds

    def __call__(self, materialized, *, timeout_seconds: int, cancel_event: threading.Event) -> SyntaxResult:
        argv = [
            self.executable,
            "--syntax-check",
            "--inventory",
            materialized.inventory_path,
            "--extra-vars",
            f"@{Path(materialized.root) / 'env' / 'extravars'}",
            materialized.playbook_path,
        ]
        output_path = Path(materialized.root) / "syntax-output"
        descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        canceled = False
        timed_out = False
        try:
            with os.fdopen(descriptor, "wb") as output:
                process = self.popen(
                    argv,
                    cwd=str(Path(materialized.playbook_path).parent),
                    env=self._environment(materialized.root),
                    stdin=subprocess.DEVNULL,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                deadline = self.monotonic() + timeout_seconds
                while process.poll() is None:
                    if cancel_event.is_set():
                        canceled = True
                        self._stop(process)
                        break
                    if self.monotonic() >= deadline:
                        timed_out = True
                        self._stop(process)
                        break
                    self.sleep(0.1)
                exit_status = process.poll()
        finally:
            if not output_path.exists():
                return SyntaxResult(False, None, "syntax check did not produce output")

        output = output_path.read_bytes()[:MAX_DIAGNOSTIC_BYTES].decode("utf-8", errors="replace")
        return SyntaxResult(exit_status == 0 and not canceled and not timed_out, exit_status, output, canceled, timed_out)

    @staticmethod
    def _environment(root: str) -> dict[str, str]:
        return {
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "HOME": root,
            "ANSIBLE_LOCAL_TEMP": str(Path(root) / "local-tmp"),
            "ANSIBLE_HOST_KEY_CHECKING": "True",
            "ANSIBLE_RETRY_FILES_ENABLED": "False",
        }

    def _stop(self, process) -> None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=self.cancel_grace_seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=self.cancel_grace_seconds)
        except ProcessLookupError:
            pass


@dataclass(frozen=True)
class RunnerResult:
    status: str
    exit_status: int | None
    ok_count: int = 0
    changed_count: int = 0
    failed_count: int = 0
    unreachable_count: int = 0
    error_code: str | None = None
    error_detail: str | None = None


class AnsibleRunner:
    """Narrow adapter around the pinned ansible-runner Python API."""

    def __init__(self, *, max_forks: int = 5, cancel_grace_seconds: float = 10.0) -> None:
        self.max_forks = max_forks
        self.cancel_grace_seconds = cancel_grace_seconds

    def __call__(self, materialized, payload, *, cancel_event: threading.Event, event_handler=None) -> RunnerResult:
        counts = {"ok": 0, "changed": 0, "failed": 0, "unreachable": 0}
        redactor = SecretRedactor(_payload_secret_values(payload))
        options = _mapping(payload.get("options"))
        timeout_seconds = int(options.get("timeout_seconds", 3600))
        context = multiprocessing.get_context("spawn")
        messages = context.Queue(maxsize=100)
        ready = context.Event()
        child = context.Process(
            target=_ansible_runner_child,
            args=(
                materialized.root,
                Path(materialized.playbook_path).name,
                materialized.inventory_path,
                dict(options),
                self.max_forks,
                messages,
                ready,
            ),
            name="ansible-runner",
            daemon=False,
        )
        child.start()
        if not ready.wait(timeout=5):
            child.terminate()
            child.join(timeout=self.cancel_grace_seconds)
            messages.close()
            return RunnerResult(
                "failed", child.exitcode,
                error_code="runner_failed", error_detail="Ansible Runner failed to initialize"
            )
        deadline = time.monotonic() + timeout_seconds
        terminal = None

        while terminal is None:
            if cancel_event.is_set() or time.monotonic() >= deadline:
                timed_out = not cancel_event.is_set()
                self._stop_group(child)
                result = RunnerResult(
                    "failed" if timed_out else "canceled",
                    None,
                    error_code="timeout" if timed_out else "canceled",
                    error_detail="execution timed out" if timed_out else "execution canceled",
                )
                messages.close()
                return result
            try:
                kind, value = messages.get(timeout=0.1)
            except queue.Empty:
                if not child.is_alive():
                    break
                continue
            if kind == "event":
                event = value
                event_type = event["event_type"]
                if event_type == "runner_on_ok":
                    counts["ok"] += 1
                    if event.get("event_data", {}).get("res", {}).get("changed"):
                        counts["changed"] += 1
                elif event_type == "runner_on_failed":
                    counts["failed"] += 1
                elif event_type == "runner_on_unreachable":
                    counts["unreachable"] += 1
                if event_handler:
                    try:
                        event_handler(redactor.redact(event))
                    except Exception as error:
                        self._stop_group(child)
                        messages.close()
                        raise ExecutionError("event handling failed closed") from error
            elif kind == "result":
                terminal = value
            elif kind == "error":
                terminal = {"status": "failed", "rc": None, "error": redactor.redact(str(value))}

        child.join(timeout=1)
        if child.is_alive():
            self._stop_group(child)
        messages.close()
        if terminal is None:
            return RunnerResult(
                "failed", child.exitcode,
                error_code="runner_failed", error_detail="Ansible Runner exited without a result"
            )
        status = "succeeded" if terminal.get("status") == "successful" and terminal.get("rc") == 0 else "failed"
        return RunnerResult(
            status=status,
            exit_status=terminal.get("rc"),
            ok_count=counts["ok"],
            changed_count=counts["changed"],
            failed_count=counts["failed"],
            unreachable_count=counts["unreachable"],
            error_code=None if status == "succeeded" else "ansible_failed",
            error_detail=terminal.get("error"),
        )

    def _stop_group(self, child) -> None:
        if not child.is_alive():
            return
        try:
            os.killpg(child.pid, signal.SIGTERM)
            child.join(timeout=self.cancel_grace_seconds)
            if child.is_alive():
                os.killpg(child.pid, signal.SIGKILL)
                child.join(timeout=self.cancel_grace_seconds)
        except ProcessLookupError:
            child.terminate()
            child.join(timeout=1)


def _ansible_runner_child(root, playbook, inventory, options, max_forks, messages, ready) -> None:
    """Own a fresh process group so cancellation reaches Ansible and SSH children."""
    try:
        os.setsid()
        ready.set()
        import ansible_runner

        def handle(raw_event):
            messages.put(("event", _normalized_event(raw_event)))
            return True

        kwargs = {
            "private_data_dir": root,
            "playbook": playbook,
            "inventory": inventory,
            "quiet": True,
            "timeout": int(options.get("timeout_seconds", 3600)),
            "forks": max_forks,
            "event_handler": handle,
        }
        host_limit = options.get("host_limit")
        if host_limit:
            kwargs["limit"] = str(host_limit)
        if options.get("check_mode") is True:
            kwargs["cmdline"] = "--check"
        result = ansible_runner.run(**kwargs)
        messages.put(("result", {"status": result.status, "rc": result.rc}))
    except BaseException as error:  # child must return a bounded failure, never a traceback
        messages.put(("error", str(error)[:MAX_DIAGNOSTIC_BYTES]))


class RunProcessor:
    def __init__(
        self,
        *,
        client,
        target_policy,
        workspace,
        syntax_checker: Callable | None = None,
        runner: Callable | None = None,
        cancel_event: threading.Event | None = None,
        event_handler: Callable | None = None,
        event_flusher: Callable | None = None,
    ) -> None:
        self.client = client
        self.target_policy = target_policy
        self.workspace = workspace
        self.syntax_checker = syntax_checker or SyntaxChecker()
        self.runner = runner or AnsibleRunner()
        self.cancel_event = cancel_event or threading.Event()
        self.event_handler = event_handler
        self.event_flusher = event_flusher

    def process(self, claim: Mapping[str, Any], *, validate_known_hosts: bool = True) -> None:
        run_id = int(claim["id"])
        lease = str(claim["lease"])
        payload = _mapping(claim.get("payload"))
        redactor = SecretRedactor(_payload_secret_values(payload))
        try:
            targets = self._approve_targets(payload)
            if validate_known_hosts:
                KnownHostsPolicy.validate(str(payload.get("known_hosts", "")), targets)
            with self.workspace.materialize(payload, targets) as materialized:
                options = _mapping(payload.get("options"))
                timeout = int(options.get("timeout_seconds", 3600))
                syntax = self.syntax_checker(materialized, timeout_seconds=timeout, cancel_event=self.cancel_event)
                if not syntax.valid:
                    status = "canceled" if syntax.canceled else "failed"
                    code = "canceled" if syntax.canceled else ("timeout" if syntax.timed_out else "syntax_invalid")
                    self.client.finish_run(
                        run_id,
                        lease,
                        _run_result(
                            status,
                            syntax.exit_status,
                            error_code=code,
                            error_detail=redactor.redact(syntax.output),
                        ),
                    )
                    return

                self.client.start_run(run_id, lease)
                result = self.runner(
                    materialized,
                    payload,
                    cancel_event=self.cancel_event,
                    event_handler=self.event_handler,
                )
                if self.event_flusher:
                    self.event_flusher()
                self.client.finish_run(run_id, lease, _run_result_from_runner(result))
        except (ExecutionError, TargetPolicyError, KeyError, TypeError, ValueError) as error:
            detail = redactor.redact(str(error)).encode("utf-8")[:MAX_DIAGNOSTIC_BYTES].decode("utf-8", errors="ignore")
            self.client.finish_run(
                run_id,
                lease,
                _run_result("failed", None, error_code="executor_rejected", error_detail=detail),
            )

    def _approve_targets(self, payload: Mapping[str, Any]) -> list[ApprovedTarget]:
        raw_targets = payload.get("targets")
        if not isinstance(raw_targets, list) or not raw_targets:
            raise ExecutionError("run payload has no targets")
        if len(raw_targets) > MAX_TARGETS:
            raise ExecutionError("run payload has too many targets")
        return [self.target_policy.approve(_mapping(target)) for target in raw_targets]


def _run_result(
    status: str,
    exit_status: int | None,
    *,
    error_code: str | None = None,
    error_detail: str | None = None,
    counts: Mapping[str, int] | None = None,
) -> dict[str, Any]:
    counts = counts or {}
    return {
        "status": status,
        "exit_status": exit_status,
        "ok_count": int(counts.get("ok_count", 0)),
        "changed_count": int(counts.get("changed_count", 0)),
        "failed_count": int(counts.get("failed_count", 0)),
        "unreachable_count": int(counts.get("unreachable_count", 0)),
        "error_code": error_code,
        "error_detail": error_detail[:MAX_DIAGNOSTIC_BYTES] if error_detail else None,
    }


def _run_result_from_runner(result: RunnerResult) -> dict[str, Any]:
    code = result.error_code
    if code is None and result.status != "succeeded":
        code = "canceled" if result.status == "canceled" else "ansible_failed"
    return _run_result(
        result.status,
        result.exit_status,
        error_code=code,
        error_detail=result.error_detail,
        counts={
            "ok_count": result.ok_count,
            "changed_count": result.changed_count,
            "failed_count": result.failed_count,
            "unreachable_count": result.unreachable_count,
        },
    )


def _normalized_event(raw_event: Mapping[str, Any]) -> dict[str, Any]:
    data = _mapping(raw_event.get("event_data"))
    return {
        "event_uuid": str(raw_event.get("uuid") or uuid.uuid4()),
        "parent_uuid": raw_event.get("parent_uuid"),
        "counter": max(0, int(raw_event.get("counter", 0))),
        "event_type": str(raw_event.get("event") or "verbose"),
        "play": data.get("play"),
        "task": data.get("task"),
        "host": data.get("host"),
        "event_time": raw_event.get("created"),
        "stdout": raw_event.get("stdout"),
        "event_data": dict(data),
    }


def _mapping(value: object) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _nested_scalar_values(value: object) -> list[object]:
    if isinstance(value, Mapping):
        return [secret for child in value.values() for secret in _nested_scalar_values(child)]
    if isinstance(value, (list, tuple)):
        return [secret for child in value for secret in _nested_scalar_values(child)]
    if isinstance(value, (str, int, float, bool)):
        return [value]
    return []


def _payload_secret_values(payload: Mapping[str, Any]) -> list[object]:
    return _nested_scalar_values(payload.get("secrets")) + _nested_scalar_values(payload.get("variables"))
