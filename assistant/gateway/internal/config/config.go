package config

import (
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

const (
	maxSecretBytes = 16 << 10
	MCPURL         = "http://hunter-mcp:8080/mcp"
	ProxyURL       = "http://assistant-egress:3128"
	AMQPHost       = "rabbitmq:5672"
	AMQPVHost      = "hunter-assistant"

	// defaultProviderSecretDir is the read-only mount for operator-provided
	// provider API keys. Either or both may be absent.
	defaultProviderSecretDir = "/run/secrets"

	// placeholderPrefix mirrors Rails' ProviderCredentials::PLACEHOLDER so the
	// two implementations classify the same shipped example files identically.
	placeholderPrefix = "replace_with_"
)

// machineSecretDir holds the gateway-generated machine credentials (MCP
// token, AMQP password) bootstrapped on first boot. Their absence is always
// a genuine fault, unlike a provider key. This is a var rather than a const
// only so tests can redirect it into a temp directory; a later task's
// contract test asserts the default value is exactly "/run/assistant/secrets".
var machineSecretDir = "/run/assistant/secrets"

var defaultSecretFiles = map[string]string{
	"openai_primary":    "assistant_openai_api_key",
	"anthropic_primary": "assistant_anthropic_api_key",
}

type Profile struct {
	Provider  string
	Model     string
	SecretRef string
}

type SecretResolver struct {
	paths map[string]string
}

type Config struct {
	GatewayMCPToken   string
	AMQPPassword      string
	ProviderSecrets   *SecretResolver
	AvailableProfiles []string
}

// Load is the production entry point: machine credentials come from
// machineSecretDir and provider keys from the standard Compose secrets mount.
func Load() (Config, error) {
	return LoadFrom(defaultProviderSecretDir)
}

// LoadFrom reads machine credentials (mandatory) and classifies the provider
// keys found under secretDir (each optional). It never fails because a
// provider key is absent, empty, or otherwise rejected — that just keeps the
// corresponding profile out of AvailableProfiles.
func LoadFrom(secretDir string) (Config, error) {
	mcpToken, err := readSecret(filepath.Join(machineSecretDir, "assistant_gateway_mcp_token"))
	if err != nil {
		return Config{}, errors.New("gateway MCP credential unavailable")
	}
	amqpPassword, err := readSecret(filepath.Join(machineSecretDir, "assistant_gateway_amqp_password"))
	if err != nil {
		return Config{}, errors.New("gateway AMQP credential unavailable")
	}

	available := make([]string, 0, len(defaultSecretFiles))
	for reference := range defaultSecretFiles {
		if ProviderStatusIn(secretDir, reference) == "valid" {
			available = append(available, reference)
		}
	}
	sort.Strings(available)

	overrides := make(map[string]string, len(defaultSecretFiles))
	for reference, file := range defaultSecretFiles {
		overrides[reference] = filepath.Join(secretDir, file)
	}

	return Config{
		GatewayMCPToken:   mcpToken,
		AMQPPassword:      amqpPassword,
		ProviderSecrets:   NewSecretResolver(overrides),
		AvailableProfiles: available,
	}, nil
}

// ProviderStatusIn classifies the provider key file for reference within
// secretDir, using the same reason vocabulary as
// web/app/services/assistant/provider_credentials.rb: valid, absent, empty,
// placeholder, oversize, bad_mode, symlink, unreadable. No secret value is
// ever included in the result.
func ProviderStatusIn(secretDir, reference string) string {
	file, ok := defaultSecretFiles[reference]
	if !ok {
		return "absent"
	}
	return classifySecret(filepath.Join(secretDir, file))
}

func classifySecret(path string) string {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "absent"
		}
		return "unreadable"
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "symlink"
	}
	// Size precedes mode, mirroring the Rails preflight: both are decided from
	// lstat metadata before any read, and either way the file is rejected
	// without being opened.
	if info.Size() > maxSecretBytes {
		return "oversize"
	}
	if !safeSecretMode(path, info.Mode().Perm()) {
		return "bad_mode"
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "unreadable"
	}
	value := strings.TrimSpace(string(body))
	if value == "" {
		return "empty"
	}
	if strings.HasPrefix(strings.ToLower(value), placeholderPrefix) {
		return "placeholder"
	}
	return "valid"
}

func NewSecretResolver(overrides map[string]string) *SecretResolver {
	paths := make(map[string]string, len(defaultSecretFiles))
	for reference, file := range defaultSecretFiles {
		paths[reference] = filepath.Join(defaultProviderSecretDir, file)
		if candidate := overrides[reference]; candidate != "" {
			paths[reference] = candidate
		}
	}
	return &SecretResolver{paths: paths}
}

func (resolver *SecretResolver) Resolve(reference string) (string, error) {
	path, ok := resolver.paths[reference]
	if !ok {
		return "", errors.New("provider secret reference is not allowed")
	}
	return readSecret(path)
}

func ValidateProfile(profile Profile) error {
	valid := (profile.Provider == "openai" && profile.Model == "gpt-5" && profile.SecretRef == "openai_primary") ||
		(profile.Provider == "anthropic" && profile.Model == "claude-sonnet-5" && profile.SecretRef == "anthropic_primary")
	if !valid {
		return errors.New("provider profile is not in the compiled catalog")
	}
	return nil
}

func (config Config) AMQPURL() string {
	return (&url.URL{
		Scheme: "amqp",
		User:   url.UserPassword("hunter-assistant-gateway", config.AMQPPassword),
		Host:   AMQPHost,
		Path:   "/" + AMQPVHost,
	}).String()
}

func readSecret(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || !safeSecretMode(path, info.Mode().Perm()) || info.Size() <= 0 || info.Size() > maxSecretBytes {
		return "", errors.New("secret file rejected")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("secret file rejected")
	}
	value := strings.TrimSpace(string(body))
	if value == "" || strings.ContainsAny(value, "\x00\r\n\t ") {
		return "", errors.New("secret value rejected")
	}
	return value, nil
}

func safeSecretMode(path string, mode os.FileMode) bool {
	if mode == 0o400 {
		return true
	}
	if mode != 0o600 {
		return false
	}
	// Standalone Compose preserves a file-backed secret's host mode. Permit a
	// 0600 source only when the in-container read-only bind rejects write opens.
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err == nil {
		_ = file.Close()
		return false
	}
	return errors.Is(err, syscall.EROFS) || errors.Is(err, syscall.EACCES)
}
