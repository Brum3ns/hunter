package config

import (
	"strings"
	"testing"
)

func TestLoadReadsIngressTokenFromEnvironment(t *testing.T) {
	t.Setenv("ASSISTANT_VALIDATOR_INGRESS_TOKEN", strings.Repeat("i", 32))

	settings, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if settings.IngressToken != strings.Repeat("i", 32) {
		t.Fatalf("IngressToken = %q", settings.IngressToken)
	}
}

func TestLoadRejectsMissingIngressToken(t *testing.T) {
	t.Setenv("ASSISTANT_VALIDATOR_INGRESS_TOKEN", "")
	if _, err := Load(); err == nil {
		t.Fatal("Load: want error for missing ingress token")
	}
}

// Each disallowed byte gets its own case so a validCredential regression that
// only catches, say, spaces cannot pass by accident. NUL is exercised
// directly against validCredential rather than through Load/t.Setenv: a
// process environment variable cannot carry a NUL byte at all (os.Setenv
// itself rejects it), so that byte is unreachable through the env-var path
// but validCredential must still reject it defensively.
func TestLoadRejectsMalformedIngressToken(t *testing.T) {
	for name, value := range map[string]string{
		"contains CR":      "token\rvalue",
		"contains LF":      "token\nvalue",
		"contains tab":     "token\tvalue",
		"contains space":   "token value",
		"too long":         strings.Repeat("t", 1025),
		"exactly at limit": strings.Repeat("t", 1024),
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("ASSISTANT_VALIDATOR_INGRESS_TOKEN", value)
			_, err := Load()
			wantErr := name != "exactly at limit"
			if wantErr && err == nil {
				t.Fatal("expected the malformed token to be rejected")
			}
			if !wantErr && err != nil {
				t.Fatalf("expected a maximum-length token to be accepted: %v", err)
			}
		})
	}
}

func TestValidCredentialRejectsNUL(t *testing.T) {
	if validCredential("token\x00value") {
		t.Fatal("expected a NUL byte to be rejected")
	}
}
