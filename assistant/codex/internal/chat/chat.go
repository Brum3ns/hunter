package chat

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxLineBytes     = 256 << 10
	maxOutputBytes   = 1 << 20
	maxReplyBytes    = 64 << 10
	maxThreadIDBytes = 255
)

var (
	ErrLoginRequired = errors.New("codex login required")
	ErrUsageLimit    = errors.New("codex usage limit")
	ErrMalformed     = errors.New("codex output malformed")
	ErrCLIFailed     = errors.New("codex cli failed")
)

type Config struct {
	CodexHome    string
	WorkingDir   string
	Timeout      time.Duration
	MCPURL       string
	MCPToken     string
	AllowedTools []string
	SystemPrompt string
}

type Request struct {
	Prompt    string
	ThreadID  string
	TurnGrant string
}

type Response struct {
	ThreadID string
	Reply    string
}

type invocation struct {
	Args []string
	Env  []string
}

func buildInvocation(cfg Config, req Request) invocation {
	args := []string{
		"exec",
		"--strict-config",
		"--json",
		"--color", "never",
		"--skip-git-repo-check",
		"--ignore-user-config",
		"--ignore-rules",
		"--disable", "shell_tool",
		"--disable", "unified_exec",
		"--disable", "browser_use",
		"--disable", "browser_use_external",
		"--disable", "browser_use_full_cdp_access",
		"--disable", "computer_use",
		"--disable", "apps",
		"--disable", "plugins",
		"--disable", "image_generation",
		"--disable", "multi_agent",
		"--disable", "request_permissions_tool",
		"--disable", "skill_mcp_dependency_install",
		"--disable", "hooks",
		"--disable", "shell_snapshot",
		"--disable", "workspace_dependencies",
		"--disable", "remote_plugin",
		"--disable", "plugin_sharing",
		"--disable", "auth_elicitation",
		"--disable", "tool_call_mcp_elicitation",
		"--disable", "goals",
		"--config", `web_search="disabled"`,
		"--config", "allow_login_shell=false",
		"--config", `approval_policy="never"`,
		"--config", `sandbox_mode="read-only"`,
		"--config", `forced_login_method="chatgpt"`,
		"--config", "analytics.enabled=false",
		"--config", "feedback.enabled=false",
		"--config", "memories.generate_memories=false",
		"--config", "memories.use_memories=false",
	}

	home := cfg.CodexHome
	if home == "" {
		home = "/home/codex/.codex"
	}
	env := []string{
		"PATH=/usr/local/bin:/usr/bin:/bin",
		"HOME=/home/codex",
		"CODEX_HOME=" + home,
		"LANG=C.UTF-8",
		"LC_ALL=C.UTF-8",
		"TMPDIR=/tmp",
	}

	if mcpEnabled(cfg, req) {
		args = append(args,
			"--config", "mcp_servers.hunter.url="+tomlString(cfg.MCPURL),
			"--config", `mcp_servers.hunter.bearer_token_env_var="HUNTER_MCP_TOKEN"`,
			"--config", `mcp_servers.hunter.env_http_headers={"X-Hunter-Turn-Grant"="HUNTER_TURN_GRANT"}`,
			"--config", "mcp_servers.hunter.enabled_tools="+tomlStringArray(cfg.AllowedTools),
			"--config", "mcp_servers.hunter.required=true",
		)
		if cfg.SystemPrompt != "" {
			args = append(args, "--config", "developer_instructions="+tomlString(cfg.SystemPrompt))
		}
		env = append(env,
			"HUNTER_MCP_TOKEN="+cfg.MCPToken,
			"HUNTER_TURN_GRANT="+req.TurnGrant,
		)
	}

	if req.ThreadID != "" {
		args = append(args, "resume", req.ThreadID)
	}
	args = append(args, req.Prompt)
	return invocation{Args: args, Env: env}
}

func mcpEnabled(cfg Config, req Request) bool {
	return cfg.MCPURL != "" && cfg.MCPToken != "" && len(cfg.AllowedTools) > 0 && validGrant(req.TurnGrant)
}

func validGrant(grant string) bool {
	if len(grant) == 0 || len(grant) > 1024 {
		return false
	}
	return !strings.ContainsAny(grant, "\x00\r\n\t ")
}

func tomlString(value string) string {
	return strconv.Quote(value)
}

func tomlStringArray(values []string) string {
	quoted := make([]string, 0, len(values))
	for _, value := range values {
		quoted = append(quoted, tomlString(value))
	}
	return "[" + strings.Join(quoted, ",") + "]"
}

func Run(ctx context.Context, bin string, cfg Config, req Request) (Response, error) {
	if cfg.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, cfg.Timeout)
		defer cancel()
	}

	inv := buildInvocation(cfg, req)
	cmd := exec.CommandContext(ctx, bin, inv.Args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killProcessGroup(cmd) }
	cmd.Env = inv.Env
	cmd.Stderr = io.Discard
	if cfg.WorkingDir != "" {
		cmd.Dir = cfg.WorkingDir
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return Response{}, ErrCLIFailed
	}
	if err := cmd.Start(); err != nil {
		return Response{}, ErrCLIFailed
	}

	result, parseErr := parseJSONL(stdout)
	if parseErr != nil {
		_ = killProcessGroup(cmd)
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return Response{}, ErrCLIFailed
	}
	if parseErr != nil {
		return Response{}, parseErr
	}
	if waitErr != nil {
		return Response{}, ErrCLIFailed
	}
	return result, nil
}

func killProcessGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	if errors.Is(err, syscall.ESRCH) {
		return nil
	}
	return err
}

func parseJSONL(reader io.Reader) (Response, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 16<<10), maxLineBytes)

	var result Response
	var totalBytes int
	var finalMessages int
	var completed bool

	for scanner.Scan() {
		line := scanner.Bytes()
		totalBytes += len(line) + 1
		if totalBytes > maxOutputBytes || len(line) == 0 || completed {
			return Response{}, ErrMalformed
		}

		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(line, &envelope); err != nil || envelope == nil {
			return Response{}, ErrMalformed
		}
		var eventType string
		if err := json.Unmarshal(envelope["type"], &eventType); err != nil {
			return Response{}, ErrMalformed
		}

		switch eventType {
		case "thread.started":
			if result.ThreadID != "" {
				continue
			}
			if err := json.Unmarshal(envelope["thread_id"], &result.ThreadID); err != nil ||
				!boundedNonBlank(result.ThreadID, maxThreadIDBytes) {
				return Response{}, ErrMalformed
			}
		case "turn.started", "item.started", "item.updated":
			// These known progress events carry no response field this boundary uses.
		case "item.completed":
			var item struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}
			if err := json.Unmarshal(envelope["item"], &item); err != nil || item.Type == "" {
				return Response{}, ErrMalformed
			}
			if item.Type == "agent_message" {
				finalMessages++
				if finalMessages != 1 || !boundedNonBlank(item.Text, maxReplyBytes) {
					return Response{}, ErrMalformed
				}
				result.Reply = item.Text
			}
		case "turn.completed":
			completed = true
		case "turn.failed", "error":
			return Response{}, classifyFailure(envelope["error"])
		default:
			return Response{}, ErrMalformed
		}
	}
	if scanner.Err() != nil {
		return Response{}, ErrMalformed
	}
	if !completed || finalMessages != 1 || !boundedNonBlank(result.ThreadID, maxThreadIDBytes) ||
		!boundedNonBlank(result.Reply, maxReplyBytes) {
		return Response{}, ErrMalformed
	}
	return result, nil
}

func classifyFailure(raw json.RawMessage) error {
	var failure struct {
		Category string `json:"category"`
		Code     string `json:"code"`
		Type     string `json:"type"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &failure) != nil {
		return ErrCLIFailed
	}
	for _, category := range []string{failure.Category, failure.Code, failure.Type} {
		switch category {
		case "authentication", "authentication_error", "auth", "login_required", "unauthorized":
			return ErrLoginRequired
		case "usage_limit", "usage_limit_reached", "rate_limit", "rate_limit_exceeded", "quota_exceeded":
			return ErrUsageLimit
		}
	}
	return ErrCLIFailed
}

func boundedNonBlank(value string, limit int) bool {
	return len(value) <= limit && strings.TrimSpace(value) != ""
}
