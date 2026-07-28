import base64
import hashlib
import unittest

from ansible_executor.hunter_ansible.target_policy import ApprovedTarget
from ansible_executor.hunter_ansible.tasks import HostKeyScanner, TaskProcessor


class Completed:
    returncode = 0
    stdout = "10.20.1.8 ssh-ed25519 " + base64.b64encode(b"public key blob").decode() + "\n"


class HostKeyScannerTest(unittest.TestCase):
    def test_uses_fixed_argv_and_rewrites_scanned_address_to_inventory_alias(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            return Completed()

        scanner = HostKeyScanner(run=run)
        candidate = scanner.scan([ApprovedTarget("worker", "10.20.1.8", 22, ("10.20.1.8",))])[0]

        self.assertEqual(["/usr/bin/ssh-keyscan", "-T", "10", "-p", "22", "10.20.1.8"], calls[0][0])
        self.assertNotIn("shell", calls[0][1])
        self.assertTrue(candidate["known_hosts_line"].startswith("worker ssh-ed25519 "))
        expected = base64.b64encode(hashlib.sha256(b"public key blob").digest()).decode().rstrip("=")
        self.assertEqual(f"SHA256:{expected}", candidate["fingerprint"])


class Policy:
    def approve(self, target):
        return ApprovedTarget(target["host"], target["address"], target["port"], (target["address"],))


class Client:
    def __init__(self):
        self.results = []

    def finish_task(self, task_id, lease, result):
        self.results.append((task_id, lease, result))


class Scanner:
    def scan(self, targets):
        return [{"host": targets[0].host, "port": 22, "known_hosts_line": "worker ssh-ed25519 AAAA", "fingerprint": "SHA256:test"}]


class TaskProcessorTest(unittest.TestCase):
    def test_host_scan_reports_only_allowlisted_candidate_fields(self):
        client = Client()
        processor = TaskProcessor(client=client, target_policy=Policy(), workspace=None, scanner=Scanner())

        processor.process({
            "id": 3,
            "kind": "host_key_scan",
            "lease": "lease",
            "payload": {"targets": [{"host": "worker", "address": "10.20.1.8", "port": 22}]},
        })

        self.assertEqual("succeeded", client.results[0][2]["status"])
        candidate = client.results[0][2]["result"]["candidates"][0]
        self.assertEqual({"host", "port", "known_hosts_line", "fingerprint"}, set(candidate))


if __name__ == "__main__":
    unittest.main()
