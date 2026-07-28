package chat

import (
	"context"
	"errors"
	"os"
	"path/filepath"
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
	got, err := Run(context.Background(), bin, Request{Prompt: "hi"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.SessionID != "sess_1" || got.Reply != "Hello there." {
		t.Fatalf("got %+v", got)
	}
}

func TestRunMalformed(t *testing.T) {
	bin := fakeClaude(t, "not json", 0)
	if _, err := Run(context.Background(), bin, Request{Prompt: "hi"}); !errors.Is(err, ErrMalformed) {
		t.Fatalf("want ErrMalformed, got %v", err)
	}
}

func TestRunLoginRequired(t *testing.T) {
	// Non-zero exit with an auth-shaped stderr surfaces as ErrLoginRequired.
	bin := fakeClaude(t, `{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}`, 1)
	if _, err := Run(context.Background(), bin, Request{Prompt: "hi"}); !errors.Is(err, ErrLoginRequired) {
		t.Fatalf("want ErrLoginRequired, got %v", err)
	}
}
