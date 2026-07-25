import ipaddress
import unittest

from ansible_executor.hunter_ansible.config import Config, ConfigError, normalize_token


class ConfigTest(unittest.TestCase):
    def base_env(self):
        return {
            "HUNTER_URL": "http://web:5000",
            "HUNTER_RUNNER_TOKEN": "x" * 43,
            "ANSIBLE_ALLOWED_CIDRS": "10.20.0.0/16,fd00::/64",
        }

    def test_requires_url_token_and_nonempty_allowed_cidrs(self):
        for missing in ("HUNTER_URL", "HUNTER_RUNNER_TOKEN", "ANSIBLE_ALLOWED_CIDRS"):
            env = self.base_env()
            env.pop(missing)
            with self.subTest(missing=missing), self.assertRaises(ConfigError):
                Config.from_env(env)

    def test_rejects_url_credentials_query_fragment_and_insecure_remote_http(self):
        invalid = [
            "https://user:pass@example.com",
            "https://example.com?token=x",
            "https://example.com/#fragment",
            "http://example.com",
        ]
        for url in invalid:
            env = self.base_env() | {"HUNTER_URL": url}
            with self.subTest(url=url), self.assertRaises(ConfigError):
                Config.from_env(env)

    def test_parses_network_ports_and_operational_defaults(self):
        config = Config.from_env(self.base_env() | {"ANSIBLE_ALLOWED_PORTS": "22,2222"})

        self.assertEqual((ipaddress.ip_network("10.20.0.0/16"), ipaddress.ip_network("fd00::/64")), config.allowed_cidrs)
        self.assertEqual((22, 2222), config.allowed_ports)
        self.assertEqual(2.0, config.poll_seconds)
        self.assertEqual(15.0, config.heartbeat_seconds)
        self.assertEqual(45.0, config.lease_seconds)
        self.assertEqual(100, config.max_event_batch)
        self.assertEqual(5 * 1024 * 1024, config.max_buffer_bytes)
        self.assertEqual("/runner", config.workspace_root)

    def test_normalizes_one_layer_of_env_quotes(self):
        self.assertEqual("token-value", normalize_token('  "token-value"  '))
        self.assertEqual("token-value", normalize_token(" 'token-value' "))

    def test_special_target_override_is_restricted_to_local_development(self):
        env = self.base_env() | {
            "HUNTER_URL": "https://hunter.example.com",
            "ANSIBLE_ALLOW_SPECIAL_TARGETS": "true",
        }
        with self.assertRaises(ConfigError):
            Config.from_env(env)


if __name__ == "__main__":
    unittest.main()
