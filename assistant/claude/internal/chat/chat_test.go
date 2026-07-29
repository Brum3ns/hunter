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
	req := Request{Prompt: "hi", TurnGrant: "grant-abc"}

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

func TestBuildInvocationWithMCPValidGrant(t *testing.T) {
	tools := []string{"mcp__hunter__list_targets", "mcp__hunter__get_target"}
	cfg := Config{MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "shared-tok", AllowedTools: tools}
	req := Request{Prompt: "hi", SessionID: "sess_1", TurnGrant: "grant-abc"}

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
	if hunter.Headers["X-Hunter-Turn-Grant"] != "grant-abc" {
		t.Fatalf("got grant header %q", hunter.Headers["X-Hunter-Turn-Grant"])
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
	req := Request{Prompt: "hi", TurnGrant: "grant-abc"}
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

func TestBuildInvocationFallsBackOnEmptyGrant(t *testing.T) {
	cfg := Config{MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "tok", AllowedTools: []string{"mcp__hunter__list_targets"}}
	args, path, cleanup, err := buildInvocation(cfg, Request{Prompt: "hi", TurnGrant: ""})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	defer cleanup()
	if path != "" {
		t.Fatalf("want no config file for empty grant, got %q", path)
	}
	want := []string{"-p", "hi", "--output-format", "json", "--allowedTools", ""}
	if !slices.Equal(args, want) {
		t.Fatalf("got %v want %v", args, want)
	}
}

// TestBuildInvocationFallsBackOnInvalidGrant covers every way a grant can be
// malformed per the gateway's validGrant rule: a missing or malformed grant
// must NEVER cause an (unauthenticated) MCP config file to be written.
func TestBuildInvocationFallsBackOnInvalidGrant(t *testing.T) {
	cfg := Config{MCPURL: "http://hunter-mcp:8080/mcp", MCPToken: "tok", AllowedTools: []string{"mcp__hunter__list_targets"}}
	cases := map[string]string{
		"space":    "has space",
		"tab":      "has\ttab",
		"newline":  "has\nnewline",
		"cr":       "has\rcr",
		"nul":      "has\x00nul",
		"too long": strings.Repeat("a", 1025),
	}
	for name, grant := range cases {
		t.Run(name, func(t *testing.T) {
			_, path, cleanup, err := buildInvocation(cfg, Request{Prompt: "hi", TurnGrant: grant})
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			defer cleanup()
			if path != "" {
				t.Fatalf("want no config file, got %q", path)
			}
		})
	}
}

func TestBuildInvocationNoMCPWhenURLEmptyEvenWithValidGrant(t *testing.T) {
	// A valid grant alone must not enable MCP; cfg.MCPURL must also be set.
	args, path, cleanup, err := buildInvocation(Config{}, Request{Prompt: "hi", TurnGrant: "grant-abc"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	defer cleanup()
	if path != "" {
		t.Fatalf("want no config file when MCPURL is empty, got %q", path)
	}
	want := []string{"-p", "hi", "--output-format", "json", "--allowedTools", ""}
	if !slices.Equal(args, want) {
		t.Fatalf("got %v want %v", args, want)
	}
}
