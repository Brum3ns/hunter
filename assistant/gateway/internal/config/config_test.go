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

// Each machine token is checked in isolation. Zeroing both at once (above)
// passes even if one side of Load's || were dropped, so each token gets a case
// where it is the *only* thing wrong.
func TestLoadFailsWhenEitherMachineTokenAloneIsMissing(t *testing.T) {
	t.Run("MCP token missing, ingress token valid", func(t *testing.T) {
		t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", "")
		t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", strings.Repeat("i", 32))
		if _, err := Load(); err == nil {
			t.Fatal("expected an error when only the MCP token is missing")
		}
	})

	t.Run("ingress token missing, MCP token valid", func(t *testing.T) {
		t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", strings.Repeat("m", 32))
		t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", "")
		if _, err := Load(); err == nil {
			t.Fatal("expected an error when only the ingress token is missing")
		}
	})
}

// A provider key that is never set and one that is set to an empty string
// must both fail to become available: "absent" and "empty" are distinct
// reason codes but neither is usable. ProviderStatus covers the codes
// themselves; this asserts Load wires os.LookupEnv's presence flag through
// correctly rather than collapsing it.
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

// Every reason code in the shared vocabulary, produced directly by
// ProviderStatus. The whitespace-only-and-oversize row is the ordering guard:
// Ruby's reason_for decides oversize on the raw byte size before it ever
// strips, so that input must report oversize rather than empty. A later
// contract test pins this vocabulary against Ruby's and needs every code
// reachable through this one exported function.
func TestProviderStatusCoversEveryReasonCode(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		value   string
		present bool
		want    string
	}{
		{name: "unset variable", value: "", present: false, want: "absent"},
		{name: "unset beats a value that would otherwise classify", value: "sk-live", present: false, want: "absent"},
		{name: "oversize", value: strings.Repeat("k", maxSecretBytes+1), present: true, want: "oversize"},
		{name: "oversize whitespace is not empty", value: strings.Repeat(" ", maxSecretBytes+1), present: true, want: "oversize"},
		{name: "exactly at the limit is not oversize", value: strings.Repeat("k", maxSecretBytes), present: true, want: "valid"},
		{name: "empty string", value: "", present: true, want: "empty"},
		{name: "whitespace only", value: "   \n\t", present: true, want: "empty"},
		{name: "placeholder", value: "replace_with_openai_api_key", present: true, want: "placeholder"},
		{name: "placeholder is case insensitive", value: "REPLACE_WITH_ANTHROPIC_API_KEY", present: true, want: "placeholder"},
		{name: "placeholder after surrounding whitespace", value: "  replace_with_key\n", present: true, want: "placeholder"},
		{name: "valid", value: "sk-ant-real", present: true, want: "valid"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := ProviderStatus(testCase.value, testCase.present); got != testCase.want {
				t.Fatalf("ProviderStatus(%d bytes, present=%v) = %q, want %q",
					len(testCase.value), testCase.present, got, testCase.want)
			}
		})
	}
}

func TestProviderStatusNeverLeaksTheValue(t *testing.T) {
	if got := ProviderStatus("sk-canary", true); strings.Contains(got, "sk-canary") {
		t.Fatalf("a reason code leaked the secret value: %q", got)
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
