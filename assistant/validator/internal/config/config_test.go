package config

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAcceptsOnlyAMQPPasswordFromAMode0400RegularFile(t *testing.T) {
	secret := filepath.Join(t.TempDir(), "amqp-password")
	if err := os.WriteFile(secret, []byte("strong/password\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(secret, 0o400); err != nil {
		t.Fatal(err)
	}

	settings, err := LoadFrom(secret)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(settings.AMQPURL())
	if err != nil {
		t.Fatal(err)
	}
	password, present := parsed.User.Password()
	if parsed.Scheme != "amqp" || parsed.Host != "rabbitmq:5672" || parsed.Path != "/hunter-assistant" || parsed.User.Username() != "hunter-assistant-validator" || !present || password != "strong/password" {
		t.Fatalf("unexpected AMQP URL components: scheme=%q host=%q path=%q user=%q password_present=%v", parsed.Scheme, parsed.Host, parsed.Path, parsed.User.Username(), present)
	}
}

func TestLoadRejectsLooseSymlinkAndMalformedSecrets(t *testing.T) {
	root := t.TempDir()
	tests := map[string]func(string) error{
		"loose mode": func(path string) error {
			if err := os.WriteFile(path, []byte("secret"), 0o600); err != nil {
				return err
			}
			return os.Chmod(path, 0o600)
		},
		"whitespace": func(path string) error { return os.WriteFile(path, []byte("two words"), 0o400) },
		"symlink": func(path string) error {
			target := filepath.Join(root, "target")
			if err := os.WriteFile(target, []byte("secret"), 0o400); err != nil {
				return err
			}
			return os.Symlink(target, path)
		},
	}
	for name, prepare := range tests {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(root, name)
			if err := prepare(path); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadFrom(path); err == nil {
				t.Fatal("expected secret rejection")
			}
		})
	}
}
