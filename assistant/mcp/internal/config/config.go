package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"
)

const (
	maxSecretBytes  = 16 * 1024
	defaultBindAddr = "0.0.0.0:8080"
)

type Config struct {
	BindAddress        string
	GatewayToken       string
	HunterServiceToken string
	HunterBaseURL      string
	AllowedHosts       []string
	AllowedOrigins     []string
	MaxRequestBytes    int64
	MaxResponseBytes   int64
	RequestTimeout     time.Duration
}

func Load() (Config, error) {
	gatewayToken, err := secretFromEnv("ASSISTANT_GATEWAY_MCP_TOKEN")
	if err != nil {
		return Config{}, fmt.Errorf("load gateway credential: %w", err)
	}
	hunterToken, err := secretFromEnv("ASSISTANT_MCP_HUNTER_TOKEN")
	if err != nil {
		return Config{}, fmt.Errorf("load Hunter credential: %w", err)
	}

	baseURL := envOr("ASSISTANT_HUNTER_URL", "http://web:5000")
	if err := validateBaseURL(baseURL, splitList(envOr("ASSISTANT_HUNTER_ALLOWED_HOSTS", "web:5000"))); err != nil {
		return Config{}, err
	}

	return Config{
		BindAddress:        defaultBindAddr,
		GatewayToken:       gatewayToken,
		HunterServiceToken: hunterToken,
		HunterBaseURL:      baseURL,
		AllowedHosts:       splitList(envOr("ASSISTANT_MCP_ALLOWED_HOSTS", "hunter-mcp:8080")),
		AllowedOrigins:     splitList(os.Getenv("ASSISTANT_MCP_ALLOWED_ORIGINS")),
		MaxRequestBytes:    1 << 20,
		MaxResponseBytes:   64 << 10,
		RequestTimeout:     15 * time.Second,
	}, nil
}

// secretFromEnv reads a machine token from the environment. Secrets used to
// arrive as 0400 files on a read-only mount, which let this service verify the
// mode and reject a world-readable key; an environment variable carries no such
// proof, so the only checks left are on the value itself. The rejection of
// embedded NUL/CR/LF/tab/space matches the gateway and validator readers, so a
// token one service accepts is a token all three accept.
//
// The value is never echoed: callers get a static reason, never the secret.
func secretFromEnv(name string) (string, error) {
	raw, present := os.LookupEnv(name)
	if !present {
		return "", errors.New("secret is not set")
	}
	if len(raw) > maxSecretBytes {
		return "", errors.New("secret is too large")
	}
	secret := strings.TrimSpace(raw)
	if secret == "" {
		return "", errors.New("secret is empty")
	}
	if strings.ContainsAny(secret, "\x00\r\n\t ") {
		return "", errors.New("secret contains disallowed characters")
	}
	return secret, nil
}

func validateBaseURL(raw string, allowedHosts []string) error {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return errors.New("Hunter URL is invalid")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return errors.New("Hunter URL must contain only scheme and authority")
	}
	if !slices.Contains(allowedHosts, parsed.Host) {
		return errors.New("Hunter URL host is not allowlisted")
	}
	return nil
}

func splitList(raw string) []string {
	result := make([]string, 0)
	for _, item := range strings.Split(raw, ",") {
		if item = strings.TrimSpace(item); item != "" && !slices.Contains(result, item) {
			result = append(result, item)
		}
	}
	return result
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
