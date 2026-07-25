import base64
import hashlib
import tempfile
import threading
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import subprocess

from ansible_executor.hunter_ansible.execution import (
    KnownHostsError,
    KnownHostsPolicy,
    RunProcessor,
    SecretRedactor,
    SyntaxChecker,
    SyntaxResult,
)
from ansible_executor.hunter_ansible.target_policy import ApprovedTarget


class SecretRedactorTest(unittest.TestCase):
    def test_redacts_nested_known_secrets_without_mutating_input(self):
        event = {"stdout": "token=super-secret", "event_data": {"super-secret": "super-secret"}}

        redacted = SecretRedactor(["super-secret"]).redact(event)

        self.assertEqual("token=[FILTERED]", redacted["stdout"])
        self.assertEqual("[FILTERED]", redacted["event_data"]["[FILTERED]"])
        self.assertEqual("super-secret", event["event_data"]["super-secret"])


class KnownHostsPolicyTest(unittest.TestCase):
    def key_line(self, host="worker"):
        blob = b"synthetic public key blob"
        encoded = base64.b64encode(blob).decode()
        fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
        return f"{host} ssh-ed25519 {encoded}", fingerprint

    def test_requires_a_matching_entry_for_every_approved_alias(self):
        line, fingerprint = self.key_line()
        target = ApprovedTarget("worker", "10.20.1.8", 22, ("10.20.1.8",))

        KnownHostsPolicy.validate(line, [target])
        self.assertEqual(fingerprint, KnownHostsPolicy.fingerprint(line))

        with self.assertRaises(KnownHostsError):
            KnownHostsPolicy.validate(line.replace("worker", "other"), [target])


class FakePolicy:
    def approve(self, target):
        return ApprovedTarget(target["host"], target["address"], target.get("port", 22), (target["address"],))


class FakeWorkspace:
    @contextmanager
    def materialize(self, payload, targets):
        with tempfile.TemporaryDirectory() as root:
            playbook = Path(root) / "playbook.yml"
            inventory = Path(root) / "inventory.yml"
            playbook.write_text(payload["playbook_yaml"])
            inventory.write_text(payload["inventory_yaml"])
            value = type("Materialized", (), {
                "root": root,
                "playbook_path": str(playbook),
                "inventory_path": str(inventory),
            })()
            yield value


class FakeClient:
    def __init__(self):
        self.results = []
        self.started = []

    def finish_run(self, run_id, lease, result):
        self.results.append((run_id, lease, result))

    def start_run(self, run_id, lease):
        self.started.append((run_id, lease))


class RunProcessorTest(unittest.TestCase):
    def test_syntax_failure_is_reported_before_runner_execution(self):
        client = FakeClient()
        runner_called = []
        checker = lambda *_args, **_kwargs: SyntaxResult(False, 4, "bad syntax PRIVATE")
        processor = RunProcessor(
            client=client,
            target_policy=FakePolicy(),
            workspace=FakeWorkspace(),
            syntax_checker=checker,
            runner=lambda *_args, **_kwargs: runner_called.append(True),
        )
        claim = {
            "id": 7,
            "lease": "lease",
            "payload": {
                "targets": [{"host": "worker", "address": "10.20.1.8", "port": 22}],
                "playbook_yaml": "---\n- hosts: all\n",
                "inventory_yaml": "---\nall:\n  hosts:\n    worker: {}\n",
                "known_hosts": "worker ssh-ed25519 AAAA",
                "variables": {},
                "secrets": {"private_key": "PRIVATE"},
                "options": {"timeout_seconds": 60, "check_mode": False, "host_limit": None},
            },
        }

        processor.process(claim, validate_known_hosts=False)

        self.assertEqual([], client.started)
        self.assertEqual([], runner_called)
        result = client.results[0][2]
        self.assertEqual("failed", result["status"])
        self.assertEqual("syntax_invalid", result["error_code"])
        self.assertNotIn("PRIVATE", str(result))


class SyntaxCheckerTest(unittest.TestCase):
    def test_cancellation_terminates_then_kills_the_process_group(self):
        calls = []

        class Process:
            pid = 4321
            returncode = None

            def poll(self):
                return self.returncode

            def wait(self, timeout):
                calls.append(("wait", timeout))
                if len([call for call in calls if call[0] == "wait"]) == 1:
                    raise subprocess.TimeoutExpired("ansible-playbook", timeout)
                self.returncode = -9
                return self.returncode

        def popen(argv, **kwargs):
            calls.append(("popen", argv, kwargs))
            return Process()

        materialized = type("Materialized", (), {
            "root": tempfile.mkdtemp(),
            "playbook_path": "/tmp/project/playbook.yml",
            "inventory_path": "/tmp/inventory/inventory.yml",
        })()
        cancel = threading.Event()
        cancel.set()
        checker = SyntaxChecker(popen=popen, cancel_grace_seconds=0.01)

        with patch("ansible_executor.hunter_ansible.execution.os.killpg") as killpg:
            result = checker(materialized, timeout_seconds=60, cancel_event=cancel)

        popen_call = calls[0]
        self.assertEqual("/usr/local/bin/ansible-playbook", popen_call[1][0])
        self.assertTrue(popen_call[2]["start_new_session"])
        self.assertNotIn("shell", popen_call[2])
        self.assertEqual([15, 9], [call.args[1] for call in killpg.call_args_list])
        self.assertTrue(result.canceled)


if __name__ == "__main__":
    unittest.main()
