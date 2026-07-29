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
	// is enabled. It MUST contain only "mcp__hunter__*" read tool names —
	// never a Claude Code built-in (Bash/Write/Edit/Read/WebFetch/...).
	AllowedTools []string
	// SystemPrompt, when non-empty, is appended to the CLI's default system
	// prompt (--append-system-prompt) on MCP-enabled turns. It carries the
	// tool-use policy that keeps the model from calling a read tool unless the
	// user explicitly asks for a Hunter data lookup. Empty disables the append.
	SystemPrompt string
}

type Request struct {
	Prompt    string
	SessionID string
	// TurnGrant is the per-turn credential Rails issues for this turn
	// (Issuer.call); it is presented to hunter-mcp as X-Hunter-Turn-Grant. A
	// missing or malformed grant disables MCP for the turn — it never causes
	// an unauthenticated MCP config to be written (see validGrant).
	TurnGrant string
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

// buildInvocation assembles the claude CLI argv and, when MCP is enabled for
// this turn, writes the per-request --mcp-config file next to it. Given the
// same cfg/req it always produces the same argv shape; the only side effect
// is that one temp file, and the returned cleanup always removes exactly
// that file (or is a no-op when none was written).
//
// MCP is enabled only when cfg.MCPURL is set AND req.TurnGrant passes
// validGrant. A missing or malformed grant is not an error: buildInvocation
// silently falls back to the no-MCP argv, because writing an MCP config
// without a valid grant would hand the CLI an unauthenticated path to
// hunter-mcp — the one thing this function must never do.
func buildInvocation(cfg Config, req Request) (args []string, mcpConfigPath string, cleanup func(), err error) {
	noop := func() {}

	args = []string{"-p", req.Prompt, "--output-format", "json"}
	if req.SessionID != "" {
		args = append(args, "--resume", req.SessionID)
	}

	if cfg.MCPURL == "" || !validGrant(req.TurnGrant) {
		args = append(args, "--allowedTools", "")
		return args, "", noop, nil
	}

	payload, marshalErr := json.Marshal(mcpConfigFile{
		MCPServers: map[string]mcpServerConfig{
			"hunter": {
				Type: "http",
				URL:  cfg.MCPURL,
				Headers: map[string]string{
					"Authorization":       "Bearer " + cfg.MCPToken,
					"X-Hunter-Turn-Grant": req.TurnGrant,
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

// validGrant mirrors the MCP gateway's own rule
// (assistant/mcp/internal/auth/middleware.go's validGrant) so both sides of
// the trust boundary agree on what a well-formed grant looks like.
func validGrant(grant string) bool {
	if len(grant) == 0 || len(grant) > 1024 {
		return false
	}
	return !strings.ContainsAny(grant, "\x00\r\n\t ")
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
