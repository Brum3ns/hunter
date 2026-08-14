package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hunter.local/assistant/codex/internal/chat"
)

const testHost = "assistant-codex:8084"

func TestChatChecksMethodThenHostThenBearerBeforeReadingBody(t *testing.T) {
	tests := []struct {
		name   string
		method string
		host   string
		auth   string
		want   int
		code   string
	}{
		{name: "method first", method: http.MethodGet, host: "evil:8084", want: http.StatusMethodNotAllowed, code: "method_not_allowed"},
		{name: "host second", method: http.MethodPost, host: "evil:8084", want: http.StatusForbidden, code: "host_not_allowed"},
		{name: "bearer third", method: http.MethodPost, host: testHost, want: http.StatusUnauthorized, code: "unauthorized"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			body := &countingBody{reader: strings.NewReader(`{"prompt":"must not be read"}`)}
			request := httptest.NewRequest(test.method, "http://"+test.host+"/chat", nil)
			request.Host = test.host
			request.Body = body
			if test.auth != "" {
				request.Header.Set("Authorization", test.auth)
			}
			response := httptest.NewRecorder()

			newChatHandler("ingress-secret", []string{testHost}, "unused", chat.Config{}).ServeHTTP(response, request)

			assertErrorResponse(t, response, test.want, test.code)
			if got := body.reads.Load(); got != 0 {
				t.Fatalf("body read %d times before gate rejection", got)
			}
		})
	}
}

func TestChatRejectsWrongSameLengthBearer(t *testing.T) {
	request := validChatRequest(strings.NewReader(`{"prompt":"hello"}`))
	request.Header.Set("Authorization", "Bearer ingress-secreu")
	response := httptest.NewRecorder()

	newChatHandler("ingress-secret", []string{testHost}, "unused", chat.Config{}).ServeHTTP(response, request)

	assertErrorResponse(t, response, http.StatusUnauthorized, "unauthorized")
}

func TestChatRejectsEmptyConfiguredBearer(t *testing.T) {
	request := validChatRequest(strings.NewReader(`{"prompt":"hello"}`))
	request.Header.Del("Authorization")
	response := httptest.NewRecorder()

	newChatHandler("", []string{testHost}, "unused", chat.Config{}).ServeHTTP(response, request)

	assertErrorResponse(t, response, http.StatusUnauthorized, "unauthorized")
}

func TestBearerComparisonHashesVariableLengthTokensBeforeConstantTimeBoundary(t *testing.T) {
	presented := "short"
	configured := "configured-token-with-a-different-length"
	comparisonCalled := false

	matched := authorizedBearerWithComparator("Bearer "+presented, configured, func(left, right []byte) int {
		comparisonCalled = true
		if len(left) != 32 || len(right) != 32 {
			t.Fatalf("constant-time boundary received variable lengths %d and %d", len(left), len(right))
		}
		if got := hex.EncodeToString(left); got != "f9b0078b5df596d2ea19010c001bbd009e651de2c57e8fb7e355f31eb9d3f739" {
			t.Fatalf("presented operand is not its SHA-256 digest: %s", got)
		}
		if got := hex.EncodeToString(right); got != "e621fa5d656b8249586a722699b4326eef5593ea7470e6ff2472d8be8569ce9a" {
			t.Fatalf("configured operand is not its SHA-256 digest: %s", got)
		}
		if bytes.Equal(left, right) {
			return 1
		}
		return 0
	})

	if !comparisonCalled {
		t.Fatal("constant-time comparison boundary was not called")
	}
	if matched {
		t.Fatal("different bearer tokens matched")
	}
}

func TestAuthorizedBearerKeepsExactSchemeEmptyAndEqualityBehaviorClosed(t *testing.T) {
	tests := []struct {
		name   string
		header string
		token  string
		want   bool
	}{
		{name: "exact match", header: "Bearer ingress-secret", token: "ingress-secret", want: true},
		{name: "empty configured token", header: "Bearer ", token: "", want: false},
		{name: "missing scheme", header: "ingress-secret", token: "ingress-secret", want: false},
		{name: "lowercase scheme", header: "bearer ingress-secret", token: "ingress-secret", want: false},
		{name: "same length mismatch", header: "Bearer ingress-secreu", token: "ingress-secret", want: false},
		{name: "shorter mismatch", header: "Bearer short", token: "ingress-secret", want: false},
		{name: "longer mismatch", header: "Bearer ingress-secret-extra", token: "ingress-secret", want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := authorizedBearer(test.header, test.token); got != test.want {
				t.Fatalf("authorizedBearer(%q, configured token) = %v, want %v", test.header, got, test.want)
			}
		})
	}
}

func TestChatBoundsBodyOnlyAfterAuthenticatedGates(t *testing.T) {
	request := validChatRequest(strings.NewReader(strings.Repeat("x", maxRequestBytes+1)))
	response := httptest.NewRecorder()

	newChatHandler("ingress-secret", []string{testHost}, "unused", chat.Config{}).ServeHTTP(response, request)

	assertErrorResponse(t, response, http.StatusBadRequest, "invalid_request")
}

func TestChatRejectsMissingUnknownAndCrossFieldTypes(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "missing prompt", body: `{}`},
		{name: "blank prompt", body: `{"prompt":"   "}`},
		{name: "unknown field", body: `{"prompt":"hello","model":"arbitrary"}`},
		{name: "numeric prompt", body: `{"prompt":7}`},
		{name: "numeric thread id", body: `{"prompt":"hello","thread_id":7}`},
		{name: "object grant", body: `{"prompt":"hello","turn_grant":{}}`},
		{name: "trailing JSON", body: `{"prompt":"hello"}{}`},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := validChatRequest(strings.NewReader(test.body))
			response := httptest.NewRecorder()
			newChatHandler("ingress-secret", []string{testHost}, "unused", chat.Config{}).ServeHTTP(response, request)
			assertErrorResponse(t, response, http.StatusBadRequest, "invalid_request")
		})
	}
}

func TestChatReturnsExactSuccessAndSpawnsCodexOnce(t *testing.T) {
	dir := t.TempDir()
	countPath := filepath.Join(dir, "count.txt")
	bin := writeFakeCodex(t, dir, "success", "printf 'spawned\\n' >> count.txt\n"+
		"printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"thread-123\"}' "+
		"'{\"type\":\"turn.started\"}' "+
		"'{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Hello there.\"}}' "+
		"'{\"type\":\"turn.completed\"}'\n"+
		"printf '%s\\n' 'raw-stderr-auth-secret' >&2\nexit 0\n")
	request := validChatRequest(strings.NewReader(`{"prompt":"hello","thread_id":null,"turn_grant":"grant-secret"}`))
	response := httptest.NewRecorder()

	newChatHandler("ingress-secret", []string{testHost}, bin, chat.Config{WorkingDir: dir}).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", response.Code, response.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	want := map[string]any{"thread_id": "thread-123", "reply": "Hello there."}
	if len(got) != len(want) || got["thread_id"] != want["thread_id"] || got["reply"] != want["reply"] {
		t.Fatalf("got %#v want exact %#v", got, want)
	}
	count, err := os.ReadFile(countPath)
	if err != nil {
		t.Fatalf("read process count: %v", err)
	}
	if string(count) != "spawned\n" {
		t.Fatalf("one HTTP request must spawn exactly one process, got %q", count)
	}
	if strings.Contains(response.Body.String(), "raw-stderr-auth-secret") || strings.Contains(response.Body.String(), "grant-secret") || strings.Contains(response.Body.String(), "ingress-secret") {
		t.Fatalf("response leaked a credential or raw stderr: %s", response.Body.String())
	}
}

func TestChatPassesResumeThreadAsOneProcessArgument(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeCodex(t, dir, "resume", "printf '%s\\n' \"$@\" > args.txt\n"+
		"printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"thread-123\"}' "+
		"'{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"resumed\"}}' "+
		"'{\"type\":\"turn.completed\"}'\n")
	request := validChatRequest(strings.NewReader(`{"prompt":"hello","thread_id":"thread-123"}`))
	response := httptest.NewRecorder()

	newChatHandler("ingress-secret", []string{testHost}, bin, chat.Config{WorkingDir: dir}).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", response.Code, response.Body.String())
	}
	args, err := os.ReadFile(filepath.Join(dir, "args.txt"))
	if err != nil {
		t.Fatalf("read argv: %v", err)
	}
	if !strings.Contains(string(args), "\nresume\nthread-123\nhello\n") {
		t.Fatalf("resume command/thread/prompt sequence missing from argv:\n%s", args)
	}
}

func TestChatMapsCodexFailuresToClosedErrorsWithoutRawData(t *testing.T) {
	tests := []struct {
		name     string
		category string
		status   int
		code     string
	}{
		{name: "login", category: "authentication", status: http.StatusServiceUnavailable, code: "codex_login_required"},
		{name: "usage", category: "usage_limit", status: http.StatusTooManyRequests, code: "codex_usage_limit"},
		{name: "generic", category: "raw-provider-category", status: http.StatusBadGateway, code: "codex_error"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			bin := writeFakeCodex(t, dir, "failure", "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"raw-thread-secret\"}' "+
				"'{\"type\":\"turn.failed\",\"error\":{\"category\":\""+test.category+"\",\"message\":\"raw-stdout-secret\"}}'\n"+
				"printf '%s\\n' 'raw-stderr-secret' >&2\nexit 1\n")
			request := validChatRequest(strings.NewReader(`{"prompt":"raw-prompt-secret","turn_grant":"raw-grant-secret"}`))
			response := httptest.NewRecorder()

			newChatHandler("ingress-secret", []string{testHost}, bin, chat.Config{WorkingDir: dir}).ServeHTTP(response, request)

			assertErrorResponse(t, response, test.status, test.code)
			for _, secret := range []string{"raw-provider-category", "raw-thread-secret", "raw-stdout-secret", "raw-stderr-secret", "raw-prompt-secret", "raw-grant-secret", "ingress-secret"} {
				if strings.Contains(response.Body.String(), secret) {
					t.Fatalf("response leaked %q: %s", secret, response.Body.String())
				}
			}
		})
	}
}

func TestChatCancellationKillsRunningCodex(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeCodex(t, dir, "blocked", "printf 'started\\n' > started.txt\nexec sleep 30\n")
	ctx, cancel := context.WithCancel(context.Background())
	request := validChatRequest(strings.NewReader(`{"prompt":"hello"}`)).WithContext(ctx)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		newChatHandler("ingress-secret", []string{testHost}, bin, chat.Config{WorkingDir: dir}).ServeHTTP(response, request)
		close(done)
	}()

	startedPath := filepath.Join(dir, "started.txt")
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(startedPath); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("fake Codex did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()

	select {
	case <-done:
		assertErrorResponse(t, response, http.StatusBadGateway, "codex_error")
	case <-time.After(2 * time.Second):
		t.Fatal("handler did not return after request context cancellation")
	}
}

func TestHealthzReturnsNoContentOnlyForGet(t *testing.T) {
	handler := newHealthHandler()
	for _, test := range []struct {
		method string
		want   int
	}{
		{method: http.MethodGet, want: http.StatusNoContent},
		{method: http.MethodPost, want: http.StatusMethodNotAllowed},
	} {
		request := httptest.NewRequest(test.method, "http://"+testHost+"/healthz", nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != test.want {
			t.Fatalf("%s: want %d, got %d", test.method, test.want, response.Code)
		}
	}
}

type countingBody struct {
	reader io.Reader
	reads  atomic.Int32
}

func (body *countingBody) Read(buffer []byte) (int, error) {
	body.reads.Add(1)
	return body.reader.Read(buffer)
}

func (*countingBody) Close() error { return nil }

func validChatRequest(body io.Reader) *http.Request {
	request := httptest.NewRequest(http.MethodPost, "http://"+testHost+"/chat", body)
	request.Host = testHost
	request.Header.Set("Authorization", "Bearer ingress-secret")
	return request
}

func assertErrorResponse(t *testing.T, response *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("want %d, got %d: %s", status, response.Code, response.Body.String())
	}
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if body.Error.Code != code {
		t.Fatalf("want code %q, got %q in %s", code, body.Error.Code, response.Body.String())
	}
}

func writeFakeCodex(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatalf("write fake Codex: %v", err)
	}
	return path
}
