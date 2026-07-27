package config

import (
	"errors"
	"os"
	"sort"
	"strings"
)

const (
	maxSecretBytes = 16 << 10
	MCPURL         = "http://hunter-mcp:8080/mcp"

	// placeholderPrefix mirrors Rails' ProviderCredentials::PLACEHOLDER so the
	// two implementations classify the same environment-supplied value
	// identically.
	placeholderPrefix = "replace_with_"
)

// providerSecretEnv maps each provider profile reference to the environment
// variable that carries its API key. These names are fixed by Task 1's
// Rails-side catalog (web/config/assistant_provider_catalog.yml's secret_env:
// keys) — they must not drift independently of that file.
var providerSecretEnv = map[string]string{
	"openai_primary":    "ASSISTANT_OPENAI_API_KEY",
	"anthropic_primary": "ASSISTANT_ANTHROPIC_API_KEY",
}

type Profile struct {
	Provider  string
	Model     string
	SecretRef string
}

type SecretResolver struct {
	values map[string]string
}

type Config struct {
	GatewayMCPToken string
	IngressToken    string

	ProviderSecrets   *SecretResolver
	AvailableProfiles []string
}

// Load is the production entry point: every credential — the two machine
// tokens and both provider keys — comes from the process environment. It
// fails only when a machine credential (MCP token or ingress token) is
// missing or malformed; a provider key that is absent, empty, or otherwise
// rejected just keeps the corresponding profile out of AvailableProfiles.
func Load() (Config, error) {
	mcpToken := os.Getenv("ASSISTANT_GATEWAY_MCP_TOKEN")
	ingressToken := os.Getenv("ASSISTANT_GATEWAY_INGRESS_TOKEN")
	if !validCredential(mcpToken) || !validCredential(ingressToken) {
		return Config{}, errors.New("assistant gateway machine credential rejected")
	}

	values := make(map[string]string, len(providerSecretEnv))
	available := make([]string, 0, len(providerSecretEnv))
	for reference, name := range providerSecretEnv {
		// os.LookupEnv, not os.Getenv: Getenv collapses "unset" and "set to
		// empty" into the same "", which would make an absent key
		// indistinguishable from an empty one. Both halves of the lookup go
		// to ProviderStatus so it can make the same distinction Ruby's
		// reason_for makes with its ENV[...].nil? check.
		raw, present := os.LookupEnv(name)
		values[reference] = raw
		if ProviderStatus(raw, present) == "valid" {
			available = append(available, reference)
		}
	}
	sort.Strings(available) // map iteration order is random; AvailableProfiles is logged and asserted on.

	return Config{
		GatewayMCPToken:   mcpToken,
		IngressToken:      ingressToken,
		ProviderSecrets:   &SecretResolver{values: values},
		AvailableProfiles: available,
	}, nil
}

// ProviderStatus classifies one provider key environment variable into a
// single stable reason code, returning exactly one of "absent", "oversize",
// "empty", "placeholder" or "valid" and nothing else. present is the second
// return of os.LookupEnv, so an unset variable is distinguishable from one
// set to the empty string.
//
// The order mirrors web/app/services/assistant/provider_credentials.rb's
// reason_for exactly, and must keep doing so — a contract test pins the two
// vocabularies together. absent first, then oversize on the RAW byte length,
// then empty after stripping whitespace, then placeholder (case-insensitive
// "replace_with_" prefix), else valid. Ordering oversize ahead of empty is
// load-bearing: an over-long run of whitespace is oversize, not empty.
//
// The value's contents are never included in the result.
func ProviderStatus(value string, present bool) string {
	if !present {
		return "absent"
	}
	if len(value) > maxSecretBytes {
		return "oversize"
	}
	body := strings.TrimSpace(value)
	if body == "" {
		return "empty"
	}
	if strings.HasPrefix(strings.ToLower(body), placeholderPrefix) {
		return "placeholder"
	}
	return "valid"
}

func (resolver *SecretResolver) Resolve(reference string) (string, error) {
	value, ok := resolver.values[reference]
	if !ok {
		return "", errors.New("unknown provider reference")
	}
	if !validCredential(value) {
		return "", errors.New("unusable provider credential")
	}
	return value, nil
}

func ValidateProfile(profile Profile) error {
	valid := (profile.Provider == "openai" && profile.Model == "gpt-5" && profile.SecretRef == "openai_primary") ||
		(profile.Provider == "anthropic" && profile.Model == "claude-sonnet-5" && profile.SecretRef == "anthropic_primary")
	if !valid {
		return errors.New("provider profile is not in the compiled catalog")
	}
	return nil
}

// validCredential rejects NUL, CR, LF, tab and space. Duplicated from
// internal/mcp's helper of the same name rather than shared: internal/mcp
// already imports this package for config.MCPURL, so importing back would be
// a cycle.
func validCredential(value string) bool {
	return value != "" && len(value) <= 1024 && !strings.ContainsAny(value, "\x00\r\n\t ")
}
