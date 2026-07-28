package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestChatRequiresBearer(t *testing.T) {
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true") // "true" = a bin that exits 0
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "assistant-claude:8083"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

// An empty configured token disables ingress auth: a request with NO
// Authorization header at all must still pass the auth gate and reach the CLI
// stage (here returning the fake CLI's success), trusting the network boundary.
func TestChatEmptyTokenDisablesAuth(t *testing.T) {
	out := `{"type":"result","subtype":"success","session_id":"sess_1","result":"Hello there."}`
	bin := fakeClaude(t, out, 0)
	h := newChatHandler("", []string{"assistant-claude:8083"}, bin)
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi","session_id":null}`))
	r.Host = "assistant-claude:8083"
	// deliberately no Authorization header
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("want 200 (auth disabled), got %d: %s", w.Code, w.Body.String())
	}
}

// A non-empty configured token must still reject a request lacking the bearer,
// so disabling auth is strictly opt-in via an empty token.
func TestChatNonEmptyTokenStillEnforces(t *testing.T) {
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true")
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "assistant-claude:8083"
	// no Authorization header, but a token is configured
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 (token configured), got %d", w.Code)
	}
}

func TestChatRejectsDisallowedHost(t *testing.T) {
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true")
	r := httptest.NewRequest("POST", "http://evil:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "evil:8083"
	r.Header.Set("Authorization", "Bearer tok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", w.Code)
	}
}

func TestChatRejectsDisallowedHostBeforeCheckingBearer(t *testing.T) {
	// Host is checked before the bearer token, so a wrong host is reported
	// as host_not_allowed even with no Authorization header at all.
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true")
	r := httptest.NewRequest("POST", "http://evil:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "evil:8083"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", w.Code)
	}
}

func TestChatRejectsWrongMethod(t *testing.T) {
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true")
	r := httptest.NewRequest("GET", "http://assistant-claude:8083/chat", nil)
	r.Host = "assistant-claude:8083"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("want 405, got %d", w.Code)
	}
}

func TestChatRejectsMissingScheme(t *testing.T) {
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true")
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "assistant-claude:8083"
	r.Header.Set("Authorization", "tok") // no "Bearer " scheme
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

func TestChatRejectsEmptyPrompt(t *testing.T) {
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, "true")
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":""}`))
	r.Host = "assistant-claude:8083"
	r.Header.Set("Authorization", "Bearer tok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", w.Code)
	}
}

// fakeClaude writes a fake `claude` script that prints out and exits rc,
// mirroring internal/chat's test helper so the handler can be driven
// end-to-end without the real CLI.
func fakeClaude(t *testing.T, out string, rc int) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "claude")
	script := "#!/bin/sh\nprintf '%s' '" + out + "'\nexit " + itoa(rc) + "\n"
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	return "1"
}

func TestChatSuccess(t *testing.T) {
	out := `{"type":"result","subtype":"success","session_id":"sess_1","result":"Hello there."}`
	bin := fakeClaude(t, out, 0)
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, bin)
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi","session_id":null}`))
	r.Host = "assistant-claude:8083"
	r.Header.Set("Authorization", "Bearer tok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"sess_1"`) || !strings.Contains(w.Body.String(), "Hello there.") {
		t.Fatalf("unexpected body: %s", w.Body.String())
	}
}

func TestChatMapsLoginRequired(t *testing.T) {
	bin := fakeClaude(t, `{"type":"result","is_error":true,"result":"Invalid API key . Please run /login"}`, 1)
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, bin)
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "assistant-claude:8083"
	r.Header.Set("Authorization", "Bearer tok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "claude_login_required") {
		t.Fatalf("unexpected body: %s", w.Body.String())
	}
}

func TestChatMapsMalformedResponse(t *testing.T) {
	bin := fakeClaude(t, "not json", 0)
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, bin)
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "assistant-claude:8083"
	r.Header.Set("Authorization", "Bearer tok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusBadGateway {
		t.Fatalf("want 502, got %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "claude_malformed_response") {
		t.Fatalf("unexpected body: %s", w.Body.String())
	}
}

func TestChatMapsCLIFailure(t *testing.T) {
	bin := fakeClaude(t, `{"type":"result","is_error":true,"result":"boom"}`, 1)
	h := newChatHandler("tok", []string{"assistant-claude:8083"}, bin)
	r := httptest.NewRequest("POST", "http://assistant-claude:8083/chat", strings.NewReader(`{"prompt":"hi"}`))
	r.Host = "assistant-claude:8083"
	r.Header.Set("Authorization", "Bearer tok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusBadGateway {
		t.Fatalf("want 502, got %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "claude_error") {
		t.Fatalf("unexpected body: %s", w.Body.String())
	}
}

func TestHealthzReturnsNoContent(t *testing.T) {
	h := newHealthHandler()
	r := httptest.NewRequest("GET", "http://assistant-claude:8083/healthz", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("want 204, got %d", w.Code)
	}
}

func TestSplitList(t *testing.T) {
	if got := splitList(""); got != nil {
		t.Fatalf("want nil, got %v", got)
	}
	got := splitList("a, b ,, c")
	want := []string{"a", "b", "c"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}
