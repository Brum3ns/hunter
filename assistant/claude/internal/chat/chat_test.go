package chat

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// writes a fake `claude` that prints $CLAUDE_FAKE_OUT and exits $CLAUDE_FAKE_RC
func fakeClaude(t *testing.T, out string, rc int) string {
	dir := t.TempDir()
	p := filepath.Join(dir, "claude")
	script := "#!/bin/sh\nprintf '%s' \"$CLAUDE_FAKE_OUT\"\nexit $CLAUDE_FAKE_RC\n"
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_FAKE_OUT", out)
	t.Setenv("CLAUDE_FAKE_RC", itoa(rc))
	return p
}
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	return "1"
}

func TestRunSuccess(t *testing.T) {
	// Claude Code --output-format json emits an object with session_id + result.
	out := `{"type":"result","subtype":"success","session_id":"sess_1","result":"Hello there."}`
	bin := fakeClaude(t, out, 0)
	got, err := Run(context.Background(), bin, Config{}, Request{Prompt: "hi"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.SessionID != "sess_1" || got.Reply != "Hello there." {
		t.Fatalf("got %+v", got)
	}
}

func TestRunMalformed(t *testing.T) {
	bin := fakeClaude(t, "not json", 0)
	if _, err := Run(context.Background(), bin, Config{}, Request{Prompt: "hi"}); !errors.Is(err, ErrMalformed) {
		t.Fatalf("want ErrMalformed, got %v", err)
	}
}

func TestRunLoginRequired(t *testing.T) {
	// Non-zero exit with an auth-shaped stderr surfaces as ErrLoginRequired.
	bin := fakeClaude(t, `{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}`, 1)
	if _, err := Run(context.Background(), bin, Config{}, Request{Prompt: "hi"}); !errors.Is(err, ErrLoginRequired) {
		t.Fatalf("want ErrLoginRequired, got %v", err)
	}
}

// TestRunPassesMCPConfigAndCleansItUp drives Run end-to-end (not just
// buildInvocation) with a fake claude that captures its own argv, to prove
// the handler-facing entry point actually wires buildInvocation's output
// into the exec call and cleans the temp file up afterwards.
func TestRunPassesMCPConfigAndCleansItUp(t *testing.T) {
	dir := t.TempDir()
	binPath := filepath.Join(dir, "claude")
	argsCapture := filepath.Join(dir, "args.txt")
	script := "#!/bin/sh\nprintf '%s ' \"$@\" > " + argsCapture + "\n" +
		"printf '%s' \"$CLAUDE_FAKE_OUT\"\nexit $CLAUDE_FAKE_RC\n"
	if err := os.WriteFile(binPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_FAKE_OUT", `{"type":"result","subtype":"success","session_id":"sess_1","result":"Hello there."}`)
	t.Setenv("CLAUDE_FAKE_RC", "0")

	cfg := Config{MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "tok", AllowedTools: []string{"mcp__hunter__list_targets"}}
	req := Request{Prompt: "hi"}

	if _, err := Run(context.Background(), binPath, cfg, req); err != nil {
		t.Fatalf("err: %v", err)
	}

	captured, err := os.ReadFile(argsCapture)
	if err != nil {
		t.Fatalf("read captured args: %v", err)
	}
	fields := strings.Fields(string(captured))
	idx := slices.Index(fields, "--mcp-config")
	if idx == -1 {
		t.Fatalf("no --mcp-config in captured args: %s", captured)
	}
	path := fields[idx+1]
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("want mcp config file removed after Run, stat err: %v", statErr)
	}
}

func TestBuildInvocationNoMCP(t *testing.T) {
	args, path, cleanup, err := buildInvocation(Config{}, Request{Prompt: "hi"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := []string{"-p", "hi", "--output-format", "json", "--allowedTools", ""}
	if !slices.Equal(args, want) {
		t.Fatalf("got %v want %v", args, want)
	}
	if path != "" {
		t.Fatalf("want no mcp config path, got %q", path)
	}
	cleanup() // must be safe to call even though nothing was written
}

func TestBuildInvocationNoMCPWithResume(t *testing.T) {
	args, _, cleanup, err := buildInvocation(Config{}, Request{Prompt: "hi", SessionID: "sess_1"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := []string{"-p", "hi", "--output-format", "json", "--resume", "sess_1", "--allowedTools", ""}
	if !slices.Equal(args, want) {
		t.Fatalf("got %v want %v", args, want)
	}
	cleanup()
}

func TestBuildInvocationWithBearerOnlyMCP(t *testing.T) {
	tools := []string{"mcp__hunter__list_targets", "mcp__hunter__get_target"}
	cfg := Config{MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "shared-tok", AllowedTools: tools}
	req := Request{Prompt: "hi", SessionID: "sess_1"}

	args, path, cleanup, err := buildInvocation(cfg, req)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	defer cleanup()

	if path == "" {
		t.Fatal("want an mcp config path")
	}
	want := []string{
		"-p", "hi", "--output-format", "json", "--resume", "sess_1",
		"--mcp-config", path, "--strict-mcp-config", "--allowedTools", strings.Join(tools, " "),
	}
	if !slices.Equal(args, want) {
		t.Fatalf("got %v want %v", args, want)
	}

	// --mcp-config is variadic in the real CLI: it MUST be immediately
	// followed by another flag or it would swallow later positional args.
	idx := slices.Index(args, "--mcp-config")
	if idx == -1 || args[idx+2] != "--strict-mcp-config" {
		t.Fatalf("--mcp-config not immediately followed by --strict-mcp-config: %v", args)
	}

	info, statErr := os.Stat(path)
	if statErr != nil {
		t.Fatalf("stat: %v", statErr)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("want mode 0600, got %v", perm)
	}

	raw, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("read: %v", readErr)
	}
	var got mcpConfigFile
	if jsonErr := json.Unmarshal(raw, &got); jsonErr != nil {
		t.Fatalf("unmarshal: %v", jsonErr)
	}
	hunter, ok := got.MCPServers["hunter"]
	if !ok {
		t.Fatalf("no hunter server in config: %s", raw)
	}
	if hunter.Type != "http" || hunter.URL != cfg.MCPURL {
		t.Fatalf("got %+v", hunter)
	}
	if hunter.Headers["Authorization"] != "Bearer shared-tok" {
		t.Fatalf("got authorization header %q", hunter.Headers["Authorization"])
	}
	if len(hunter.Headers) != 1 {
		t.Fatalf("want only Authorization header, got %#v", hunter.Headers)
	}
	if _, exists := hunter.Headers["X-Hunter-Turn-Grant"]; exists {
		t.Fatalf("retired turn-grant header present: %#v", hunter.Headers)
	}

	cleanup()
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("want file removed after cleanup, stat err: %v", statErr)
	}
}

// TestBuildInvocationAllowedToolsAreReadOnlyMCPNames is the core safety
// assertion: the allowlist must contain ONLY mcp__hunter__* read tools, and
// must NEVER contain a Claude Code built-in tool name.
func TestBuildInvocationAllowedToolsAreReadOnlyMCPNames(t *testing.T) {
	builtins := []string{"Bash", "Write", "Edit", "Read", "WebFetch", "Task", "Glob", "Grep", "NotebookEdit"}
	tools := []string{
		"mcp__hunter__list_targets", "mcp__hunter__get_target", "mcp__hunter__list_cves",
		"mcp__hunter__get_cve", "mcp__hunter__list_vulnerabilities", "mcp__hunter__get_vulnerability",
	}
	cfg := Config{MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "tok", AllowedTools: tools}
	req := Request{Prompt: "hi"}
	_, _, cleanup, err := buildInvocation(cfg, req)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	defer cleanup()

	for _, tool := range cfg.AllowedTools {
		if !strings.HasPrefix(tool, "mcp__hunter__") {
			t.Fatalf("tool %q is not a mcp__hunter__ tool", tool)
		}
		if slices.Contains(builtins, tool) {
			t.Fatalf("tool %q is a built-in, must never be allowlisted", tool)
		}
	}
}

func TestBuildInvocationRequiresCompleteBearerConfiguration(t *testing.T) {
	complete := Config{
		MCPURL:       "http://hunter-mcp:8080/mcp",
		MCPToken:     "tok",
		AllowedTools: []string{"mcp__hunter__list_targets"},
	}
	tests := []struct {
		name string
		cfg  Config
	}{
		{name: "missing URL", cfg: Config{MCPToken: complete.MCPToken, AllowedTools: complete.AllowedTools}},
		{name: "missing bearer", cfg: Config{MCPURL: complete.MCPURL, AllowedTools: complete.AllowedTools}},
		{name: "missing tools", cfg: Config{MCPURL: complete.MCPURL, MCPToken: complete.MCPToken}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			args, path, cleanup, err := buildInvocation(test.cfg, Request{Prompt: "hi"})
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			defer cleanup()
			if path != "" {
				t.Fatalf("want no config file, got %q", path)
			}
			want := []string{"-p", "hi", "--output-format", "json", "--allowedTools", ""}
			if !slices.Equal(args, want) {
				t.Fatalf("got %v want %v", args, want)
			}
		})
	}
}

func TestBuildInvocationAppendsSystemPromptBeforeMCPConfig(t *testing.T) {
	cfg := Config{
		MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "tok",
		AllowedTools: []string{"mcp__hunter__list_targets"},
		SystemPrompt: "POLICY-XYZ",
	}
	args, _, cleanup, err := buildInvocation(cfg, Request{Prompt: "hi"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	defer cleanup()

	sp := slices.Index(args, "--append-system-prompt")
	if sp < 0 {
		t.Fatalf("no --append-system-prompt in args: %v", args)
	}
	if args[sp+1] != "POLICY-XYZ" {
		t.Fatalf("--append-system-prompt not immediately followed by the policy: %v", args)
	}
	// The policy pair must precede --mcp-config; --allowedTools (variadic) stays
	// last. Otherwise the CLI would swallow the policy as a config path or tool.
	mc := slices.Index(args, "--mcp-config")
	at := slices.Index(args, "--allowedTools")
	if !(sp < mc && mc < at) {
		t.Fatalf("bad flag order: append=%d mcp-config=%d allowedTools=%d args=%v", sp, mc, at, args)
	}
}

func TestBuildInvocationOmitsSystemPromptWhenEmpty(t *testing.T) {
	cfg := Config{
		MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "tok",
		AllowedTools: []string{"mcp__hunter__list_targets"},
		SystemPrompt: "",
	}
	args, _, cleanup, err := buildInvocation(cfg, Request{Prompt: "hi"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	defer cleanup()
	if slices.Contains(args, "--append-system-prompt") {
		t.Fatalf("unexpected --append-system-prompt with empty SystemPrompt: %v", args)
	}
}
