"""Ephemeral Ansible Runner private-data materialization."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Mapping, Sequence


@dataclass(frozen=True)
class MaterializedWorkspace:
    root: str
    playbook_path: str
    inventory_path: str
    private_key_path: str
    known_hosts_path: str


class Workspace:
    def __init__(self, root: str) -> None:
        self.root = root

    @contextmanager
    def materialize(
        self,
        payload: Mapping[str, object],
        approved_targets: Sequence[Mapping[str, object] | object],
    ) -> Iterator[MaterializedWorkspace]:
        os.makedirs(self.root, mode=0o700, exist_ok=True)
        os.chmod(self.root, 0o700)
        workspace = Path(tempfile.mkdtemp(prefix="hunter-ansible-", dir=self.root))
        workspace.chmod(0o700)
        try:
            project = workspace / "project"
            inventory = workspace / "inventory"
            host_vars = inventory / "host_vars"
            env = workspace / "env"
            for directory in (project, inventory, host_vars, env):
                directory.mkdir(mode=0o700)

            playbook_path = project / "playbook.yml"
            inventory_path = inventory / "inventory.yml"
            private_key_path = env / "ssh_key"
            known_hosts_path = env / "known_hosts"

            secrets = _mapping(payload.get("secrets"))
            options = _mapping(payload.get("options"))
            targets = [_target_mapping(target) for target in approved_targets]
            self._write(playbook_path, str(payload.get("playbook_yaml", "")))
            self._write(inventory_path, str(payload.get("inventory_yaml", "")))
            self._write(private_key_path, str(secrets.get("private_key") or ""))
            self._write(known_hosts_path, _pinned_known_hosts(str(payload.get("known_hosts", "")), targets))
            self._write(env / "extravars", json.dumps(_mapping(payload.get("variables")), separators=(",", ":")))

            ssh_options = (
                f"-o UserKnownHostsFile={known_hosts_path} "
                "-o StrictHostKeyChecking=yes -o UpdateHostKeys=no"
            )
            envvars = {
                "ANSIBLE_HOST_KEY_CHECKING": "True",
                "ANSIBLE_SSH_ARGS": ssh_options,
                "ANSIBLE_LOCAL_TEMP": str(workspace / "local-tmp"),
                "ANSIBLE_RETRY_FILES_ENABLED": "False",
            }
            if secrets.get("private_key"):
                envvars["ANSIBLE_PRIVATE_KEY_FILE"] = str(private_key_path)
            self._write(env / "envvars", json.dumps(envvars, separators=(",", ":")))
            self._write(
                env / "settings",
                json.dumps({"job_timeout": int(options.get("timeout_seconds", 3600))}, separators=(",", ":")),
            )
            passwords = {
                "^SSH password:\\s*?$": secrets.get("ssh_password"),
                "^BECOME password.*:\\s*?$": secrets.get("become_password"),
                "^Enter passphrase for key.*:\\s*?$": secrets.get("private_key_passphrase"),
            }
            self._write(
                env / "passwords",
                json.dumps({key: value for key, value in passwords.items() if value}, separators=(",", ":")),
            )

            for target in targets:
                values = {
                    "ansible_host": target["address"],
                    "ansible_port": int(target.get("port", 22)),
                    "ansible_user": secrets.get("username"),
                    "ansible_connection": "ssh",
                    "ansible_ssh_executable": "/usr/bin/ssh",
                    "ansible_ssh_common_args": ssh_options,
                    "ansible_ssh_extra_args": ssh_options,
                    "ansible_host_key_checking": True,
                    "ansible_ssh_host_key_checking": True,
                }
                if secrets.get("ssh_password"):
                    values["ansible_password"] = secrets["ssh_password"]
                if secrets.get("become_password"):
                    values["ansible_become_password"] = secrets["become_password"]
                self._write(host_vars / f"{_safe_alias(str(target['host']))}.json", json.dumps(values, separators=(",", ":")))

            yield MaterializedWorkspace(
                root=str(workspace),
                playbook_path=str(playbook_path),
                inventory_path=str(inventory_path),
                private_key_path=str(private_key_path),
                known_hosts_path=str(known_hosts_path),
            )
        finally:
            shutil.rmtree(workspace, ignore_errors=True)

    @staticmethod
    def _write(path: Path, content: str) -> None:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as file:
            file.write(content.encode("utf-8"))
        path.chmod(0o600)


def _mapping(value: object) -> Mapping[str, object]:
    return value if isinstance(value, Mapping) else {}


def _target_mapping(value: Mapping[str, object] | object) -> Mapping[str, object]:
    if isinstance(value, Mapping):
        return value
    return {
        "host": getattr(value, "host"),
        "address": getattr(value, "address"),
        "port": getattr(value, "port"),
    }


def _safe_alias(value: str) -> str:
    if not value or value in {".", ".."} or "/" in value or "\\" in value or "\0" in value:
        raise ValueError("unsafe inventory host alias")
    return value


def _pinned_known_hosts(known_hosts: str, targets: Sequence[Mapping[str, object]]) -> str:
    source_lines = [line.strip() for line in known_hosts.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    pinned = []
    for target in targets:
        host = str(target["host"])
        address = str(target["address"])
        port = int(target.get("port", 22))
        names = {host, address}
        expected = names | {f"[{name}]:22" for name in names} if port == 22 else {
            f"[{name}]:{port}" for name in names
        }
        pinned_name = address if port == 22 and ":" not in address else f"[{address}]:{port}"
        for line in source_lines:
            fields = line.split()
            if len(fields) < 3 or not expected.intersection(fields[0].split(",")):
                continue
            candidate = " ".join([pinned_name, *fields[1:]])
            if candidate not in pinned:
                pinned.append(candidate)
    return "\n".join(pinned)
