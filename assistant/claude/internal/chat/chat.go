package chat

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
)

var (
	ErrLoginRequired = errors.New("claude login required")
	ErrMalformed     = errors.New("claude output malformed")
	ErrCLIFailed     = errors.New("claude cli failed")
)

// Config holds the process-wide settings for invoking the claude CLI. A
// zero-value Config disables MCP entirely, preserving today's behavior
// (`--allowedTools ""`, no MCP server visible to the CLI at all).
type Config struct {
	// MCPURL, when non-empty, is the HTTP endpoint of hunter-mcp
	// (e.g. "http://hunter-mcp:8080/mcp"). Empty means MCP is off.
	MCPURL string
	// MCPToken is the shared secret hunter-mcp validates on every request
	// (the same one the legacy gateway presents as ASSISTANT_GATEWAY_MCP_TOKEN).
	MCPToken string
	// AllowedTools is the --allowedTools allowlist passed to the CLI when MCP
	// is enabled. It MUST come from the reviewed Hunter catalog — never a
	// Claude Code built-in (Bash/Write/Edit/Read/WebFetch/...).
	AllowedTools []string
	// SystemPrompt, when non-empty, is appended to the CLI's default system
	// prompt (--append-system-prompt) on MCP-enabled turns. It carries the
	// reviewed read/authoring policy. Empty disables the append.
	SystemPrompt string
}

type Request struct {
	Prompt    string
	SessionID string
}

type Response struct {
	SessionID string
	Reply     string
}

// cliResult mirrors `claude -p --output-format json` output.
type cliResult struct {
	SessionID string `json:"session_id"`
	Result    string `json:"result"`
	IsError   bool   `json:"is_error"`
}

// mcpConfigFile is the on-disk shape --mcp-config expects: a map of server
// name to its transport config.
type mcpConfigFile struct {
	MCPServers map[string]mcpServerConfig `json:"mcpServers"`
}

type mcpServerConfig struct {
	Type    string            `json:"type"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

// buildInvocation assembles the claude CLI argv and, when MCP is enabled,
// writes the per-request --mcp-config file next to it. Given the
// same cfg/req it always produces the same argv shape; the only side effect
// is that one temp file, and the returned cleanup always removes exactly
// that file (or is a no-op when none was written).
//
// MCP is enabled only when its URL, bearer, and reviewed tool list are all
// configured. An incomplete configuration silently falls back to the no-MCP
// argv and never writes a credential-bearing temporary file.
func buildInvocation(cfg Config, req Request) (args []string, mcpConfigPath string, cleanup func(), err error) {
	noop := func() {}

	args = []string{"-p", req.Prompt, "--output-format", "json"}
	if req.SessionID != "" {
		args = append(args, "--resume", req.SessionID)
	}

	if cfg.MCPURL == "" || cfg.MCPToken == "" || len(cfg.AllowedTools) == 0 {
		args = append(args, "--allowedTools", "")
		return args, "", noop, nil
	}

	payload, marshalErr := json.Marshal(mcpConfigFile{
		MCPServers: map[string]mcpServerConfig{
			"hunter": {
				Type: "http",
				URL:  cfg.MCPURL,
				Headers: map[string]string{
					"Authorization": "Bearer " + cfg.MCPToken,
				},
			},
		},
	})
	if marshalErr != nil {
		return nil, "", noop, marshalErr
	}

	file, createErr := os.CreateTemp("", "hunter-mcp-config-*.json")
	if createErr != nil {
		return nil, "", noop, createErr
	}
	path := file.Name()
	cleanup = func() { os.Remove(path) }

	// os.CreateTemp already opens with perm 0600, but chmod explicitly so the
	// guarantee doesn't silently depend on that implementation detail (or on
	// umask behavior) never changing: this file carries a bearer token.
	if chmodErr := file.Chmod(0o600); chmodErr != nil {
		file.Close()
		cleanup()
		return nil, "", noop, chmodErr
	}
	if _, writeErr := file.Write(payload); writeErr != nil {
		file.Close()
		cleanup()
		return nil, "", noop, writeErr
	}
	if closeErr := file.Close(); closeErr != nil {
		cleanup()
		return nil, "", noop, closeErr
	}

	// Append the tool-use policy BEFORE --mcp-config: both --mcp-config and
	// --allowedTools are variadic, so the single-value --append-system-prompt
	// pair must not trail them or the policy would be swallowed as a config
	// path / tool name.
	if cfg.SystemPrompt != "" {
		args = append(args, "--append-system-prompt", cfg.SystemPrompt)
	}
	args = append(args, "--mcp-config", path, "--strict-mcp-config", "--allowedTools", strings.Join(cfg.AllowedTools, " "))
	return args, path, cleanup, nil
}

func Run(ctx context.Context, bin string, cfg Config, req Request) (Response, error) {
	args, _, cleanup, buildErr := buildInvocation(cfg, req)
	if buildErr != nil {
		return Response{}, ErrCLIFailed
	}
	defer cleanup()

	out, err := exec.CommandContext(ctx, bin, args...).Output()

	var parsed cliResult
	if jsonErr := json.Unmarshal(out, &parsed); jsonErr != nil {
		return Response{}, ErrMalformed
	}
	if looksLikeLogin(parsed.Result) {
		return Response{}, ErrLoginRequired
	}
	if err != nil || parsed.IsError {
		return Response{}, ErrCLIFailed
	}
	if parsed.SessionID == "" || parsed.Result == "" {
		return Response{}, ErrMalformed
	}
	return Response{SessionID: parsed.SessionID, Reply: parsed.Result}, nil
}

func looksLikeLogin(s string) bool {
	l := strings.ToLower(s)
	return strings.Contains(l, "/login") || strings.Contains(l, "invalid api key") ||
		strings.Contains(l, "not logged in") || strings.Contains(l, "authentication")
}
