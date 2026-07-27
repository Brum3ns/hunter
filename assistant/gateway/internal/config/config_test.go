package config

import (
	"os"
	"strings"
	"testing"
)

// unsetEnv forces name to be genuinely absent for the duration of the test —
// t.Setenv can only set a value, never unset one — and restores whatever was
// there before (present or absent) in cleanup, so tests can exercise the
// absent/empty distinction without leaking into siblings or the ambient
// environment.
func unsetEnv(t *testing.T, name string) {
	t.Helper()
	original, present := os.LookupEnv(name)
	if err := os.Unsetenv(name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if present {
			_ = os.Setenv(name, original)
		} else {
			_ = os.Unsetenv(name)
		}
	})
}

func setMachineTokens(t *testing.T) {
	t.Helper()
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", strings.Repeat("m", 32))
	t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", strings.Repeat("i", 32))
}

func TestLoadReadsProviderKeysFromEnvironment(t *testing.T) {
	setMachineTokens(t)
	t.Setenv("ASSISTANT_ANTHROPIC_API_KEY", "sk-ant-real")
	t.Setenv("ASSISTANT_OPENAI_API_KEY", "")

	settings, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := settings.AvailableProfiles; len(got) != 1 || got[0] != "anthropic_primary" {
		t.Fatalf("AvailableProfiles = %v, want [anthropic_primary]", got)
	}
	key, err := settings.ProviderSecrets.Resolve("anthropic_primary")
	if err != nil || key != "sk-ant-real" {
		t.Fatalf("Resolve = %q, %v", key, err)
	}
}

func TestLoadRejectsMissingIngressToken(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", strings.Repeat("m", 32))
	t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", "")
	if _, err := Load(); err == nil {
		t.Fatal("Load: want error for missing ingress token")
	}
}

func TestLoadSucceedsWithNoProviderKeys(t *testing.T) {
	setMachineTokens(t)
	unsetEnv(t, "ASSISTANT_OPENAI_API_KEY")
	unsetEnv(t, "ASSISTANT_ANTHROPIC_API_KEY")

	settings, err := Load()
	if err != nil {
		t.Fatalf("Load failed with no provider keys: %v", err)
	}
	if len(settings.AvailableProfiles) != 0 {
		t.Fatalf("expected no available profiles, got %v", settings.AvailableProfiles)
	}
}

func TestLoadSucceedsWithOnlyAnthropicConfigured(t *testing.T) {
	setMachineTokens(t)
	unsetEnv(t, "ASSISTANT_OPENAI_API_KEY")
	t.Setenv("ASSISTANT_ANTHROPIC_API_KEY", "sk-live")

	settings, err := Load()
	if err != nil {
		t.Fatalf("Load failed with one provider key: %v", err)
	}
	if got := settings.AvailableProfiles; len(got) != 1 || got[0] != "anthropic_primary" {
		t.Fatalf("expected only anthropic_primary, got %v", got)
	}
}

func TestLoadFailsWithoutMachineCredentials(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", "")
	t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", "")

	if _, err := Load(); err == nil {
		t.Fatal("expected an error when machine credentials are absent")
	}
}

// A provider key that is never set and one that is set to an empty string
// must both fail to become available. This is the one place Go's os.Getenv
// cannot mirror Ruby's ENV[...].nil? directly (see Load's comment on
// os.LookupEnv), so it gets its own end-to-end assertion through Load rather
// than through ProviderStatus, which never sees the "absent" case.
func TestLoadTreatsAnUnsetProviderKeyTheSameAsAnEmptyOne(t *testing.T) {
	setMachineTokens(t)
	unsetEnv(t, "ASSISTANT_ANTHROPIC_API_KEY")
	t.Setenv("ASSISTANT_OPENAI_API_KEY", "")

	settings, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(settings.AvailableProfiles) != 0 {
		t.Fatalf("expected no available profiles, got %v", settings.AvailableProfiles)
	}
}

func TestProviderStatusReasonsAreStableAndLeakNothing(t *testing.T) {
	if got := ProviderStatus("replace_with_openai_api_key"); got != "placeholder" {
		t.Fatalf("expected placeholder, got %q", got)
	}
	if got := ProviderStatus("REPLACE_WITH_ANTHROPIC_API_KEY"); got != "placeholder" {
		t.Fatalf("expected case-insensitive placeholder match, got %q", got)
	}
	if got := ProviderStatus("sk-canary"); got != "valid" {
		t.Fatalf("expected valid, got %q", got)
	}
	if strings.Contains(ProviderStatus("sk-canary"), "sk-canary") {
		t.Fatal("a reason code leaked the secret value")
	}
}

func TestProviderStatusCoversEmptyAndOversize(t *testing.T) {
	if got := ProviderStatus(""); got != "empty" {
		t.Fatalf("expected empty, got %q", got)
	}
	if got := ProviderStatus("   \n\t"); got != "empty" {
		t.Fatalf("expected whitespace-only to be empty, got %q", got)
	}
	if got := ProviderStatus(strings.Repeat("k", maxSecretBytes+1)); got != "oversize" {
		t.Fatalf("expected oversize, got %q", got)
	}
}

// Ruby's reason_for decides oversize on the raw byte size before it ever
// strips whitespace, so a value that is both oversize and all-whitespace must
// report oversize, not empty. The two implementations diverging on this
// ordering is exactly what a later contract test asserts against.
func TestProviderStatusOversizeTakesPriorityOverEmpty(t *testing.T) {
	if got := ProviderStatus(strings.Repeat(" ", maxSecretBytes+1)); got != "oversize" {
		t.Fatalf("expected oversize to take priority over empty, got %q", got)
	}
}

func TestSecretResolverRejectsUnknownReferencesAndMalformedValues(t *testing.T) {
	resolver := &SecretResolver{values: map[string]string{"openai_primary": "openai-key"}}
	if got, err := resolver.Resolve("openai_primary"); err != nil || got != "openai-key" {
		t.Fatalf("got=%q err=%v", got, err)
	}
	if _, err := resolver.Resolve("../../secret"); err == nil {
		t.Fatal("accepted an unknown secret reference")
	}

	spaced := &SecretResolver{values: map[string]string{"openai_primary": "sk live with space"}}
	if _, err := spaced.Resolve("openai_primary"); err == nil {
		t.Fatal("accepted a credential containing a space")
	}
}

func TestProfileMustMatchTheCompiledCatalogTuple(t *testing.T) {
	for _, profile := range []Profile{
		{Provider: "openai", Model: "gpt-5", SecretRef: "anthropic_primary"},
		{Provider: "anthropic", Model: "gpt-5", SecretRef: "openai_primary"},
		{Provider: "openai", Model: "arbitrary", SecretRef: "openai_primary"},
	} {
		if err := ValidateProfile(profile); err == nil {
			t.Fatalf("accepted %+v", profile)
		}
	}
	if err := ValidateProfile(Profile{Provider: "openai", Model: "gpt-5", SecretRef: "openai_primary"}); err != nil {
		t.Fatal(err)
	}
}
