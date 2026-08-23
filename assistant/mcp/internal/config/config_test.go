package config

import (
	"strings"
	"testing"
)

func TestSecretFromEnvAcceptsAPlausibleToken(t *testing.T) {
	t.Setenv("ASSISTANT_TEST_SECRET", "  mcp-token-value  ")

	got, err := secretFromEnv("ASSISTANT_TEST_SECRET")
	if err != nil {
		t.Fatalf("secretFromEnv: %v", err)
	}
	if got != "mcp-token-value" {
		t.Fatalf("secretFromEnv = %q, want the trimmed value", got)
	}
}

func TestSecretFromEnvRejectsUnsetEmptyOversizeAndUnsafeValues(t *testing.T) {
	// An unset variable stays distinguishable from an empty one, which is why
	// secretFromEnv uses os.LookupEnv rather than os.Getenv.
	t.Run("unset", func(t *testing.T) {
		if _, err := secretFromEnv("ASSISTANT_TEST_SECRET_ABSENT"); err == nil {
			t.Fatal("want an error for an unset variable")
		}
	})

	for name, value := range map[string]string{
		"empty":      "",
		"whitespace": "   \n",
		"oversize":   strings.Repeat("k", maxSecretBytes+1),
		"space":      "has a space",
		"tab":        "has\ttab",
		"newline":    "has\nnewline",
		"carriage":   "has\rreturn",
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("ASSISTANT_TEST_SECRET", value)
			if _, err := secretFromEnv("ASSISTANT_TEST_SECRET"); err == nil {
				t.Fatalf("want an error for a %s value", name)
			}
		})
	}
}

func TestSecretFromEnvNeverEchoesTheValue(t *testing.T) {
	const canary = "mcp-canary\nsecret"
	t.Setenv("ASSISTANT_TEST_SECRET", canary)

	_, err := secretFromEnv("ASSISTANT_TEST_SECRET")
	if err == nil {
		t.Fatal("want an error for a value containing a newline")
	}
	if strings.Contains(err.Error(), "canary") {
		t.Fatalf("the error leaked the secret value: %v", err)
	}
}

func TestLoadReadsBothMachineTokensFromTheEnvironment(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", "gateway-mcp-token")
	t.Setenv("ASSISTANT_MCP_HUNTER_TOKEN", "mcp-hunter-token")

	settings, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if settings.GatewayToken != "gateway-mcp-token" {
		t.Fatalf("GatewayToken = %q", settings.GatewayToken)
	}
	if settings.HunterServiceToken != "mcp-hunter-token" {
		t.Fatalf("HunterServiceToken = %q", settings.HunterServiceToken)
	}
	if settings.HunterBaseURL != "http://web:5000" {
		t.Fatalf("HunterBaseURL = %q, want the default", settings.HunterBaseURL)
	}
	if settings.MaxResponseBytes != 1<<20 {
		t.Fatalf("MaxResponseBytes = %d, want the reviewed 1 MiB call ceiling", settings.MaxResponseBytes)
	}
}

func TestLoadFailsWhenEitherMachineTokenAloneIsMissing(t *testing.T) {
	t.Run("gateway token missing", func(t *testing.T) {
		t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", "")
		t.Setenv("ASSISTANT_MCP_HUNTER_TOKEN", "mcp-hunter-token")
		if _, err := Load(); err == nil {
			t.Fatal("want an error when the gateway token is missing")
		}
	})

	t.Run("hunter token missing", func(t *testing.T) {
		t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", "gateway-mcp-token")
		t.Setenv("ASSISTANT_MCP_HUNTER_TOKEN", "")
		if _, err := Load(); err == nil {
			t.Fatal("want an error when the Hunter token is missing")
		}
	})
}

func TestLoadRejectsAHunterURLOutsideTheAllowlist(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", "gateway-mcp-token")
	t.Setenv("ASSISTANT_MCP_HUNTER_TOKEN", "mcp-hunter-token")
	t.Setenv("ASSISTANT_HUNTER_URL", "http://evil.example.com")

	if _, err := Load(); err == nil {
		t.Fatal("want an error for a Hunter URL that is not allowlisted")
	}
}
