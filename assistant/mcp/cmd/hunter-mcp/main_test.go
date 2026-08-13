package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"hunter.local/assistant/mcp/internal/auth"
)

func TestHTTPHandlerExposesOnlyStatusHealthAndAuthenticatedMCP(t *testing.T) {
	mcpHandler := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	})
	authenticator := auth.NewMiddleware("gateway-secret", []string{"hunter-mcp:8080"}, nil, 1024)
	handler := newHTTPHandler(mcpHandler, authenticator)

	health := httptest.NewRequest(http.MethodGet, "http://localhost/healthz", nil)
	healthResponse := httptest.NewRecorder()
	handler.ServeHTTP(healthResponse, health)
	if healthResponse.Code != http.StatusNoContent || healthResponse.Body.Len() != 0 {
		t.Fatalf("health status=%d body=%q", healthResponse.Code, healthResponse.Body.String())
	}
	if healthResponse.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("health response may be cached")
	}

	request := httptest.NewRequest(http.MethodPost, "http://hunter-mcp:8080/mcp", strings.NewReader(`{}`))
	request.Host = "hunter-mcp:8080"
	request.Header.Set("Content-Type", "application/json")
	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, request)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d", unauthorized.Code)
	}

	request.Header.Set("Authorization", "Bearer gateway-secret")
	request.Header.Set("X-Hunter-Turn-Grant", "turn-grant")
	authorized := httptest.NewRecorder()
	handler.ServeHTTP(authorized, request)
	if authorized.Code != http.StatusAccepted {
		t.Fatalf("authorized status=%d", authorized.Code)
	}

	unknown := httptest.NewRequest(http.MethodGet, "http://localhost/debug", nil)
	unknownResponse := httptest.NewRecorder()
	handler.ServeHTTP(unknownResponse, unknown)
	if unknownResponse.Code != http.StatusNotFound {
		t.Fatalf("unknown status=%d", unknownResponse.Code)
	}
}

func TestHealthRejectsNonGETMethods(t *testing.T) {
	handler := newHTTPHandler(http.NotFoundHandler(), auth.NewMiddleware("token", []string{"hunter-mcp:8080"}, nil, 1024))
	request := httptest.NewRequest(http.MethodPost, "http://localhost/healthz", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status=%d", response.Code)
	}
}

func TestInstructionsStateBoundedReadsAndDork(t *testing.T) {
	lower := strings.ToLower(hunterInstructions)
	for _, want := range []string{"read", "non-secret", "count", "page", "limit", "dork", "id", "create"} {
		if !strings.Contains(lower, want) {
			t.Fatalf("instructions missing %q", want)
		}
	}
}

func TestInstructionsStateNarrowAuthoringScope(t *testing.T) {
	lower := strings.ToLower(hunterInstructions)
	for _, want := range []string{
		"four dedicated authoring tools", "create", "explicitly edit", "current lock version",
		"never overwrites", "no tool deletes", "validated server-side",
	} {
		if !strings.Contains(lower, want) {
			t.Fatalf("instructions missing %q", want)
		}
	}
}
