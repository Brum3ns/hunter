import json
import os
import tempfile
import unittest
from pathlib import Path

from ansible_executor.hunter_ansible.workspace import Workspace


class WorkspaceTest(unittest.TestCase):
    def payload(self):
        return {
            "playbook_yaml": "---\n- hosts: all\n  tasks: []\n",
            "inventory_yaml": "---\nall:\n  hosts:\n    worker: {}\n",
            "known_hosts": "worker ssh-ed25519 AAAA",
            "variables": {"release": "2026.07", "token": "secret-token"},
            "secrets": {"username": "deploy", "private_key": "PRIVATE KEY", "ssh_password": None, "private_key_passphrase": "key-pass", "become_password": "sudo-pass"},
            "options": {"host_limit": None, "check_mode": False, "timeout_seconds": 3600},
        }

    def test_materializes_mode_0700_workspace_and_0600_files_then_cleans_up(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root)
            with workspace.materialize(self.payload(), [{"host": "worker", "address": "10.20.1.8", "port": 22}]) as materialized:
                path = Path(materialized.root)
                self.assertEqual(0o700, path.stat().st_mode & 0o777)
                for child in path.rglob("*"):
                    if child.is_file():
                        self.assertEqual(0o600, child.stat().st_mode & 0o777, child)
                self.assertEqual("PRIVATE KEY", Path(materialized.private_key_path).read_text())
                self.assertEqual(
                    "10.20.1.8 ssh-ed25519 AAAA",
                    (path / "env" / "known_hosts").read_text(),
                )
                host_vars = json.loads((path / "inventory" / "host_vars" / "worker.json").read_text())
                self.assertEqual("10.20.1.8", host_vars["ansible_host"])
                self.assertEqual("deploy", host_vars["ansible_user"])
                self.assertEqual("ssh", host_vars["ansible_connection"])
                self.assertEqual("/usr/bin/ssh", host_vars["ansible_ssh_executable"])
                self.assertIn("StrictHostKeyChecking=yes", host_vars["ansible_ssh_common_args"])
            self.assertFalse(path.exists())

    def test_cleanup_runs_when_materialization_body_raises(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = Workspace(root)
            with self.assertRaisesRegex(RuntimeError, "boom"):
                with workspace.materialize(self.payload(), [{"host": "worker", "address": "10.20.1.8", "port": 22}]) as materialized:
                    path = Path(materialized.root)
                    raise RuntimeError("boom")
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
