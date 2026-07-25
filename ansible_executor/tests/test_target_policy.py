import socket
import unittest

from ansible_executor.hunter_ansible.target_policy import TargetPolicy, TargetPolicyError


class TargetPolicyTest(unittest.TestCase):
    def resolver(self, answers):
        def resolve(host, port, type=socket.SOCK_STREAM):
            return [(socket.AF_INET6 if ":" in address else socket.AF_INET, type, 6, "", (address, port)) for address in answers[host]]
        return resolve

    def test_resolves_every_address_inside_allowed_cidrs_and_pins_one(self):
        policy = TargetPolicy(["10.20.0.0/16"], [22], resolver=self.resolver({"worker": ["10.20.1.8", "10.20.1.9"]}))

        target = policy.approve({"host": "worker-1", "address": "worker", "port": 22})

        self.assertEqual("worker-1", target.host)
        self.assertEqual("10.20.1.8", target.address)
        self.assertEqual(("10.20.1.8", "10.20.1.9"), target.resolved_addresses)

    def test_rejects_if_any_address_is_outside_policy(self):
        policy = TargetPolicy(["10.20.0.0/16"], [22], resolver=self.resolver({"worker": ["10.20.1.8", "203.0.113.9"]}))

        with self.assertRaises(TargetPolicyError):
            policy.approve({"host": "worker", "address": "worker", "port": 22})

    def test_rejects_unapproved_ports_and_special_addresses(self):
        policy = TargetPolicy(["0.0.0.0/0"], [22], resolver=self.resolver({"worker": ["127.0.0.1"]}))
        with self.assertRaises(TargetPolicyError):
            policy.approve({"host": "worker", "address": "worker", "port": 22})
        with self.assertRaises(TargetPolicyError):
            policy.approve({"host": "worker", "address": "worker", "port": 2222})

    def test_test_only_flag_allows_explicitly_cidred_loopback(self):
        policy = TargetPolicy(["127.0.0.0/8"], [22], resolver=self.resolver({"worker": ["127.0.0.1"]}), allow_special=True)
        self.assertEqual("127.0.0.1", policy.approve({"host": "worker", "address": "worker", "port": 22}).address)


if __name__ == "__main__":
    unittest.main()
