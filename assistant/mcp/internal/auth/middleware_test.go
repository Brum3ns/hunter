package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMiddlewareRequiresExactBearerGrantHostOriginAndJSON(t *testing.T) {
	middleware := NewMiddleware("gateway-secret", []string{"hunter-mcp:8080"}, []string{"http://hunter-gateway:8080"}, 1024)
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if GrantFromContext(r.Context()) != "turn-grant" {
			t.Fatal("grant missing from context")
		}
		w.WriteHeader(http.StatusNoContent)
	})
	handler := middleware.Wrap(next)

	request := httptest.NewRequest(http.MethodPost, "http://hunter-mcp:8080/mcp", strings.NewReader(`{}`))
	request.Host = "hunter-mcp:8080"
	request.Header.Set("Authorization", "Bearer gateway-secret")
	request.Header.Set("X-Hunter-Turn-Grant", "turn-grant")
	request.Header.Set("Origin", "http://hunter-gateway:8080")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status=%d", response.Code)
	}

	for name, mutate := range map[string]func(*http.Request){
		"token":  func(r *http.Request) { r.Header.Set("Authorization", "Bearer wrong") },
		"grant":  func(r *http.Request) { r.Header.Del("X-Hunter-Turn-Grant") },
		"host":   func(r *http.Request) { r.Host = "evil.test" },
		"origin": func(r *http.Request) { r.Header.Set("Origin", "https://evil.test") },
		"type":   func(r *http.Request) { r.Header.Set("Content-Type", "text/plain") },
	} {
		t.Run(name, func(t *testing.T) {
			req := request.Clone(request.Context())
			mutate(req)
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, req)
			if res.Code < 400 {
				t.Fatalf("status=%d", res.Code)
			}
		})
	}
}

func TestMiddlewareCapsBodies(t *testing.T) {
	handler := NewMiddleware("gateway-secret", []string{"hunter-mcp:8080"}, nil, 4).Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	request := httptest.NewRequest(http.MethodPost, "http://hunter-mcp:8080/mcp", strings.NewReader("12345"))
	request.Host = "hunter-mcp:8080"
	request.Header.Set("Authorization", "Bearer gateway-secret")
	request.Header.Set("X-Hunter-Turn-Grant", "turn-grant")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d", response.Code)
	}
}
