package config

import (
	"os"
	"path/filepath"
	"testing"
)

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
