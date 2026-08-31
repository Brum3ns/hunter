package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMiddlewareAcceptsOneBearerWithoutGrantHostOrOriginRestrictions(t *testing.T) {
	middleware := NewMiddleware("gateway-secret", 1024)
	called := 0
	handler := middleware.Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called++
		w.WriteHeader(http.StatusNoContent)
	}))

	for _, tc := range []struct {
		name   string
		host   string
		origin string
	}{
		{name: "loopback", host: "127.0.0.1:8080"},
		{name: "docker gateway", host: "172.17.0.1:8080", origin: "http://host.docker.internal"},
		{name: "external DNS", host: "hunter.example.test", origin: "https://codex.example.test"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := jsonRequest("Bearer gateway-secret", `{}`)
			request.Host = tc.host
			if tc.origin != "" {
				request.Header.Set("Origin", tc.origin)
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusNoContent {
				t.Fatalf("status=%d body=%q", response.Code, response.Body.String())
			}
		})
	}
	if called != 3 {
		t.Fatalf("handler calls=%d, want 3", called)
	}
}

func TestMiddlewareRejectsInvalidBearersBeforeTheHandlerWithOneSafeEnvelope(t *testing.T) {
	const secret = "gateway-secret-canary"
	called := false
	handler := NewMiddleware(secret, 1024).Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		called = true
	}))

	for name, header := range map[string]string{
		"absent":      "",
		"malformed":   "Basic gateway-secret-canary",
		"empty":       "Bearer ",
		"wrong":       "Bearer wrong",
		"space":       "Bearer gateway secret",
		"trailing":    "Bearer gateway-secret-canary ",
		"second word": "Bearer gateway-secret-canary extra",
	} {
		t.Run(name, func(t *testing.T) {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, jsonRequest(header, `{}`))
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("status=%d", response.Code)
			}
			if response.Body.String() != "{\"error\":\"request_rejected\"}\n" {
				t.Fatalf("body=%q", response.Body.String())
			}
			if strings.Contains(response.Body.String(), secret) {
				t.Fatal("response leaked bearer")
			}
		})
	}
	if called {
		t.Fatal("handler ran for a rejected bearer")
	}
}

func TestMiddlewareKeepsJSONAndBodyLimits(t *testing.T) {
	handler := NewMiddleware("gateway-secret", 4).Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	wrongType := jsonRequest("Bearer gateway-secret", `{}`)
	wrongType.Header.Set("Content-Type", "text/plain")
	wrongTypeResponse := httptest.NewRecorder()
	handler.ServeHTTP(wrongTypeResponse, wrongType)
	if wrongTypeResponse.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("wrong type status=%d", wrongTypeResponse.Code)
	}

	tooLarge := jsonRequest("Bearer gateway-secret", "12345")
	tooLargeResponse := httptest.NewRecorder()
	handler.ServeHTTP(tooLargeResponse, tooLarge)
	if tooLargeResponse.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("large body status=%d", tooLargeResponse.Code)
	}
}

func jsonRequest(authorization, body string) *http.Request {
	request := httptest.NewRequest(http.MethodPost, "http://arbitrary.example/mcp", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if authorization != "" {
		request.Header.Set("Authorization", authorization)
	}
	return request
}
