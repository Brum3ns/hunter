package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strings"
	"syscall"
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
	gatewayPath := envOr("ASSISTANT_GATEWAY_MCP_TOKEN_FILE", "/run/assistant/secrets/assistant_gateway_mcp_token")
	hunterPath := envOr("ASSISTANT_MCP_HUNTER_TOKEN_FILE", "/run/assistant/secrets/assistant_mcp_hunter_token")
	gatewayToken, err := ReadSecret(gatewayPath)
	if err != nil {
		return Config{}, fmt.Errorf("load gateway credential: %w", err)
	}
	hunterToken, err := ReadSecret(hunterPath)
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

func ReadSecret(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", errors.New("secret file unavailable")
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("secret path is not a regular file")
	}
	if !safeSecretMode(path, info.Mode().Perm()) {
		return "", errors.New("secret file mode must be 0400")
	}
	if info.Size() <= 0 || info.Size() > maxSecretBytes {
		return "", errors.New("secret file size is invalid")
	}

	body, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("secret file unreadable")
	}
	secret := strings.TrimSpace(string(body))
	if secret == "" || strings.ContainsAny(secret, "\x00\r\n\t ") {
		return "", errors.New("secret value is invalid")
	}
	return secret, nil
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
