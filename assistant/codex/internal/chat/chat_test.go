package chat

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestBuildInvocationUsesExactHardenedArgvForNewAndResumedTurns(t *testing.T) {
	prompt := "explain --json as one argument\nwithout running anything"
	base := []string{
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

	tests := []struct {
		name     string
		threadID string
		want     []string
	}{
		{name: "new turn", want: append(slices.Clone(base), prompt)},
		{name: "resumed turn", threadID: "thread-123", want: append(slices.Clone(base), "resume", "thread-123", prompt)},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := buildInvocation(Config{}, Request{Prompt: prompt, ThreadID: test.threadID})
			if !slices.Equal(got.Args, test.want) {
				t.Fatalf("argv mismatch\n got: %#v\nwant: %#v", got.Args, test.want)
			}
			if count := countExact(got.Args, prompt); count != 1 {
				t.Fatalf("prompt must be exactly one argv element, got count %d in %#v", count, got.Args)
			}
		})
	}
}

func TestBuildInvocationUsesBearerOnlyMCPConfiguration(t *testing.T) {
	cfg := Config{
		CodexHome:    "/home/codex/.codex",
		MCPURL:       "http://hunter-mcp:8080/mcp",
		MCPToken:     "mcp-secret-xyz",
		AllowedTools: []string{"list_targets", "get_target"},
	}
	req := Request{Prompt: "hello"}

	got := buildInvocation(cfg, req)
	joinedArgs := strings.Join(got.Args, "\x00")
	if strings.Contains(joinedArgs, cfg.MCPToken) {
		t.Fatalf("MCP bearer appeared in argv")
	}
	if !slices.Contains(got.Args, `mcp_servers.hunter.bearer_token_env_var="HUNTER_MCP_TOKEN"`) {
		t.Fatalf("bearer-token environment setting missing from argv: %#v", got.Args)
	}
	if strings.Contains(joinedArgs, "env_http_headers") || strings.Contains(joinedArgs, "X-Hunter-Turn-Grant") {
		t.Fatalf("turn-grant HTTP configuration appeared in argv: %#v", got.Args)
	}
	if !slices.Contains(got.Env, "HUNTER_MCP_TOKEN=mcp-secret-xyz") {
		t.Fatalf("MCP credential missing from explicit child env: %#v", got.Env)
	}
	for _, entry := range got.Env {
		if strings.HasPrefix(entry, "HUNTER_TURN_GRANT=") {
			t.Fatalf("turn grant present in explicit child env: %#v", got.Env)
		}
	}
	for _, inherited := range []string{"OPENAI_API_KEY=", "CODEX_API_KEY="} {
		for _, entry := range got.Env {
			if strings.HasPrefix(entry, inherited) {
				t.Fatalf("API-key login variable %q present in explicit child env", entry)
			}
		}
	}
}

func TestBuildInvocationEnablesMCPOnlyForCompleteBearerConfiguration(t *testing.T) {
	complete := Config{
		MCPURL:       "http://hunter-mcp:8080/mcp",
		MCPToken:     "mcp-secret-xyz",
		AllowedTools: []string{"list_targets"},
	}
	tests := []struct {
		name string
		cfg  Config
		want bool
	}{
		{name: "complete", cfg: complete, want: true},
		{name: "missing URL", cfg: Config{MCPToken: complete.MCPToken, AllowedTools: complete.AllowedTools}},
		{name: "missing bearer", cfg: Config{MCPURL: complete.MCPURL, AllowedTools: complete.AllowedTools}},
		{name: "missing tools", cfg: Config{MCPURL: complete.MCPURL, MCPToken: complete.MCPToken}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := buildInvocation(test.cfg, Request{Prompt: "hello"})
			enabled := slices.Contains(got.Args, `mcp_servers.hunter.required=true`)
			if enabled != test.want {
				t.Fatalf("MCP enabled = %v, want %v; argv: %#v", enabled, test.want, got.Args)
			}
		})
	}
}

func TestRunUsesExplicitEnvironmentAndReturnsParsedSuccess(t *testing.T) {
	dir := t.TempDir()
	envCapture := filepath.Join(dir, "env.txt")
	bin := writeFakeCodex(t, dir, "codex-success", "env | sort > env.txt\n"+
		"printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"thread-123\"}' "+
		"'{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"reply\"}}' "+
		"'{\"type\":\"turn.completed\"}'\n"+
		"printf '%s\\n' 'stderr-auth-secret' >&2\n")
	t.Setenv("UNRELATED_HOST_SECRET", "must-not-be-inherited")

	cfg := Config{WorkingDir: dir}
	got, err := Run(context.Background(), bin, cfg, Request{Prompt: "hello"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got.ThreadID != "thread-123" || got.Reply != "reply" {
		t.Fatalf("got %+v", got)
	}

	captured, err := os.ReadFile(envCapture)
	if err != nil {
		t.Fatalf("read captured environment: %v", err)
	}
	env := string(captured)
	for _, required := range []string{"CODEX_HOME=/home/codex/.codex", "HOME=/home/codex", "PATH=/usr/local/bin:/usr/bin:/bin"} {
		if !strings.Contains(env, required+"\n") {
			t.Fatalf("missing %q from child environment:\n%s", required, env)
		}
	}
	if strings.Contains(env, "UNRELATED_HOST_SECRET") {
		t.Fatalf("child inherited unrelated host environment:\n%s", env)
	}
}

func TestRunMapsNonzeroExitWithoutLeakingRawOutput(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeCodex(t, dir, "codex-failure", "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"thread-123\"}' "+
		"'{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"raw-stdout-secret\"}}' "+
		"'{\"type\":\"turn.completed\"}'\n"+
		"printf '%s\\n' 'raw-stderr-secret' >&2\nexit 7\n")

	_, err := Run(context.Background(), bin, Config{WorkingDir: dir}, Request{Prompt: "hello"})
	if !errors.Is(err, ErrCLIFailed) {
		t.Fatalf("want ErrCLIFailed, got %v", err)
	}
	for _, secret := range []string{"raw-stdout-secret", "raw-stderr-secret"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("raw process output leaked through error: %v", err)
		}
	}
}

func TestRunKillsCodexWhenContextIsCanceled(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeCodex(t, dir, "codex-blocked", "exec sleep 30\n")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	started := time.Now()
	_, err := Run(ctx, bin, Config{WorkingDir: dir}, Request{Prompt: "hello"})
	if !errors.Is(err, ErrCLIFailed) {
		t.Fatalf("want ErrCLIFailed, got %v", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("canceled process was not killed promptly: %s", elapsed)
	}
}

func TestRunCancellationKillsTheWholeCodexProcessGroup(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeCodex(t, dir, "codex-with-child", "sleep 3 &\nchild=$!\nprintf '%s' \"$child\" > child.pid\nwait\n")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	started := time.Now()
	_, err := Run(ctx, bin, Config{WorkingDir: dir}, Request{Prompt: "hello"})
	if !errors.Is(err, ErrCLIFailed) {
		t.Fatalf("want ErrCLIFailed, got %v", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("cancellation waited for an orphaned Codex child: %s", elapsed)
	}
	rawPID, readErr := os.ReadFile(filepath.Join(dir, "child.pid"))
	if readErr != nil {
		t.Fatalf("read child pid: %v", readErr)
	}
	childPID, parseErr := strconv.Atoi(string(rawPID))
	if parseErr != nil {
		t.Fatalf("parse child pid: %v", parseErr)
	}
	t.Cleanup(func() { _ = syscall.Kill(childPID, syscall.SIGKILL) })

	deadline := time.Now().Add(time.Second)
	for processRunning(childPID) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if processRunning(childPID) {
		t.Fatalf("Codex child process %d survived context cancellation", childPID)
	}
}

func TestParseJSONLReturnsCompletedAgentMessage(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"thread.started","thread_id":"thread-123"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.started","item":{"id":"item-1","type":"agent_message"}}`,
		`{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"Hello there."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":2}}`,
	}, "\n")

	got, err := parseJSONL(strings.NewReader(stream))
	if err != nil {
		t.Fatalf("parse JSONL: %v", err)
	}
	if got.ThreadID != "thread-123" || got.Reply != "Hello there." {
		t.Fatalf("got %+v", got)
	}
}

func TestParseJSONLFailsClosedOnMalformedOrIncompleteStreams(t *testing.T) {
	tests := []struct {
		name   string
		stream string
	}{
		{name: "non-object JSON", stream: `[]`},
		{name: "malformed JSON", stream: `{"type":`},
		{name: "unknown event", stream: `{"type":"future.event"}`},
		{name: "missing thread", stream: successfulStream("", "reply")},
		{name: "missing final message", stream: strings.Join([]string{
			`{"type":"thread.started","thread_id":"thread-123"}`,
			`{"type":"turn.completed"}`,
		}, "\n")},
		{name: "whitespace final message", stream: successfulStream("thread-123", "   ")},
		{name: "missing terminal completion", stream: strings.Join([]string{
			`{"type":"thread.started","thread_id":"thread-123"}`,
			`{"type":"item.completed","item":{"type":"agent_message","text":"reply"}}`,
		}, "\n")},
		{name: "event after terminal completion", stream: successfulStream("thread-123", "reply") + "\n" + `{"type":"turn.started"}`},
		{name: "multiple terminal completions", stream: successfulStream("thread-123", "reply") + "\n" + `{"type":"turn.completed"}`},
		{name: "multiple final messages", stream: strings.Join([]string{
			`{"type":"thread.started","thread_id":"thread-123"}`,
			`{"type":"item.completed","item":{"type":"agent_message","text":"first"}}`,
			`{"type":"item.completed","item":{"type":"agent_message","text":"second"}}`,
			`{"type":"turn.completed"}`,
		}, "\n")},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseJSONL(strings.NewReader(test.stream)); !errors.Is(err, ErrMalformed) {
				t.Fatalf("want ErrMalformed, got %v", err)
			}
		})
	}
}

func TestParseJSONLFailsClosedAtEveryOutputBound(t *testing.T) {
	tests := []struct {
		name   string
		stream string
	}{
		{
			name:   "line over limit",
			stream: `{"type":"turn.started","padding":"` + strings.Repeat("x", maxLineBytes) + `"}`,
		},
		{
			name:   "reply over limit",
			stream: successfulStream("thread-123", strings.Repeat("r", maxReplyBytes+1)),
		},
		{
			name:   "thread id over limit",
			stream: successfulStream(strings.Repeat("t", maxThreadIDBytes+1), "reply"),
		},
		{
			name:   "total output over limit",
			stream: strings.Repeat(`{"type":"turn.started"}`+"\n", maxOutputBytes/24+2),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseJSONL(strings.NewReader(test.stream)); !errors.Is(err, ErrMalformed) {
				t.Fatalf("want ErrMalformed, got %v", err)
			}
		})
	}
}

func TestParseJSONLMapsOnlyKnownFailureCategories(t *testing.T) {
	tests := []struct {
		name     string
		category string
		want     error
	}{
		{name: "login required", category: "authentication", want: ErrLoginRequired},
		{name: "usage limit", category: "usage_limit", want: ErrUsageLimit},
		{name: "unknown category", category: "raw-provider-detail", want: ErrCLIFailed},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			stream := `{"type":"thread.started","thread_id":"thread-123"}` + "\n" +
				`{"type":"turn.failed","error":{"category":"` + test.category + `","message":"raw-secret"}}`
			if _, err := parseJSONL(strings.NewReader(stream)); !errors.Is(err, test.want) {
				t.Fatalf("want %v, got %v", test.want, err)
			}
		})
	}
}

func successfulStream(threadID, reply string) string {
	return strings.Join([]string{
		`{"type":"thread.started","thread_id":"` + threadID + `"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.completed","item":{"type":"agent_message","text":"` + reply + `"}}`,
		`{"type":"turn.completed"}`,
	}, "\n")
}

func countExact(values []string, target string) int {
	count := 0
	for _, value := range values {
		if value == target {
			count++
		}
	}
	return count
}

func writeFakeCodex(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	script := "#!/bin/sh\n" + body
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake Codex: %v", err)
	}
	return path
}

func processRunning(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	stat, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return false
	}
	fields := strings.Fields(string(stat))
	return len(fields) < 3 || fields[2] != "Z"
}
