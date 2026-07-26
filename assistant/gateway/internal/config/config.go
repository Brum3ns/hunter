package config

import (
	"errors"
	"net/url"
	"os"
	"strings"
	"syscall"
)

const (
	maxSecretBytes = 16 << 10
	MCPURL         = "http://hunter-mcp:8080/mcp"
	ProxyURL       = "http://assistant-egress:3128"
	AMQPHost       = "rabbitmq:5672"
	AMQPVHost      = "hunter-assistant"
)

var defaultSecretPaths = map[string]string{
	"openai_primary":    "/run/secrets/assistant_openai_api_key",
	"anthropic_primary": "/run/secrets/assistant_anthropic_api_key",
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
	GatewayMCPToken string
	AMQPPassword    string
	ProviderSecrets *SecretResolver
}

func Load() (Config, error) {
	mcpToken, err := readSecret("/run/secrets/assistant_gateway_mcp_token")
	if err != nil {
		return Config{}, errors.New("gateway MCP credential unavailable")
	}
	amqpPassword, err := readSecret("/run/secrets/assistant_gateway_amqp_password")
	if err != nil {
		return Config{}, errors.New("gateway AMQP credential unavailable")
	}
	return Config{
		GatewayMCPToken: mcpToken,
		AMQPPassword:    amqpPassword,
		ProviderSecrets: NewSecretResolver(nil),
	}, nil
}

func NewSecretResolver(overrides map[string]string) *SecretResolver {
	paths := make(map[string]string, len(defaultSecretPaths))
	for reference, path := range defaultSecretPaths {
		paths[reference] = path
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
