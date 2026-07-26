package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeSecret(t *testing.T, dir, name, value string, mode os.FileMode) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(value), mode); err != nil {
		t.Fatal(err)
	}
	// os.WriteFile's mode is subject to umask; chmod to get the exact bits.
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func writeMachineSecrets(t *testing.T, dir string) {
	t.Helper()
	original := machineSecretDir
	machineSecretDir = dir
	t.Cleanup(func() { machineSecretDir = original })
	writeSecret(t, dir, "assistant_gateway_mcp_token", "mcp-token-value", 0o400)
	writeSecret(t, dir, "assistant_gateway_amqp_password", "amqp-password-value", 0o400)
}

func TestLoadSucceedsWithNoProviderKeys(t *testing.T) {
	dir := t.TempDir()
	writeMachineSecrets(t, dir)

	settings, err := LoadFrom(dir)
	if err != nil {
		t.Fatalf("Load failed with no provider keys: %v", err)
	}
	if len(settings.AvailableProfiles) != 0 {
		t.Fatalf("expected no available profiles, got %v", settings.AvailableProfiles)
	}
}

func TestLoadSucceedsWithOnlyAnthropicConfigured(t *testing.T) {
	dir := t.TempDir()
	writeMachineSecrets(t, dir)
	writeSecret(t, dir, "assistant_anthropic_api_key", "sk-live", 0o400)

	settings, err := LoadFrom(dir)
	if err != nil {
		t.Fatalf("Load failed with one provider key: %v", err)
	}
	if got := settings.AvailableProfiles; len(got) != 1 || got[0] != "anthropic_primary" {
		t.Fatalf("expected only anthropic_primary, got %v", got)
	}
}

func TestLoadFailsWithoutMachineCredentials(t *testing.T) {
	dir := t.TempDir()
	original := machineSecretDir
	machineSecretDir = dir
	t.Cleanup(func() { machineSecretDir = original })

	if _, err := LoadFrom(dir); err == nil {
		t.Fatal("expected an error when machine credentials are absent")
	}
}

func TestProviderStatusReasonsAreStableAndLeakNothing(t *testing.T) {
	dir := t.TempDir()
	writeSecret(t, dir, "assistant_openai_api_key", "replace_with_openai_api_key", 0o400)
	writeSecret(t, dir, "assistant_anthropic_api_key", "sk-canary", 0o644)

	if got := ProviderStatusIn(dir, "openai_primary"); got != "placeholder" {
		t.Fatalf("expected placeholder, got %q", got)
	}
	if got := ProviderStatusIn(dir, "anthropic_primary"); got != "bad_mode" {
		t.Fatalf("expected bad_mode, got %q", got)
	}
	if strings.Contains(ProviderStatusIn(dir, "anthropic_primary"), "sk-canary") {
		t.Fatal("a reason code leaked the secret value")
	}
}

func TestProviderStatusReasonsCoverAbsentEmptyAndSymlink(t *testing.T) {
	dir := t.TempDir()

	if got := ProviderStatusIn(dir, "openai_primary"); got != "absent" {
		t.Fatalf("expected absent, got %q", got)
	}

	writeSecret(t, dir, "assistant_anthropic_api_key", "", 0o400)
	if got := ProviderStatusIn(dir, "anthropic_primary"); got != "empty" {
		t.Fatalf("expected empty, got %q", got)
	}

	target := filepath.Join(dir, "assistant_anthropic_api_key")
	link := filepath.Join(dir, "assistant_openai_api_key")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if got := ProviderStatusIn(dir, "openai_primary"); got != "symlink" {
		t.Fatalf("expected symlink, got %q", got)
	}
}

func TestSecretResolverUsesOnlyFixedReferencesAndOwnerReadOnlyFiles(t *testing.T) {
	dir := t.TempDir()
	openAI := filepath.Join(dir, "openai")
	if err := os.WriteFile(openAI, []byte("openai-key\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	resolver := NewSecretResolver(map[string]string{"openai_primary": openAI})
	if got, err := resolver.Resolve("openai_primary"); err != nil || got != "openai-key" {
		t.Fatalf("got=%q err=%v", got, err)
	}
	if _, err := resolver.Resolve("../../secret"); err == nil {
		t.Fatal("accepted an unknown secret reference")
	}
	if err := os.Chmod(openAI, 0o440); err != nil {
		t.Fatal(err)
	}
	if _, err := resolver.Resolve("openai_primary"); err == nil {
		t.Fatal("accepted a group-readable secret")
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
