package hunter

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClientUsesOnlyKnownRoutesAndRefusesRedirectsAndHTML(t *testing.T) {
	var path string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.EscapedPath()
		if r.Header.Get("Authorization") != "Bearer service-token" || r.Header.Get("X-Hunter-Turn-Grant") != "turn-grant" {
			t.Fatal("credentials missing")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	client, err := NewHTTPClient(server.URL, "service-token", time.Second, 64*1024)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Get(context.Background(), "turn-grant", "get_selected_context", "target", "a/b"); err != nil {
		t.Fatal(err)
	}
	if path != "/api/v1/assistant/machine/contexts/target/a%2Fb" {
		t.Fatalf("path=%q", path)
	}
	if _, err := client.Get(context.Background(), "turn-grant", "http", "target", "abc"); !errors.Is(err, ErrUnsupportedTool) {
		t.Fatalf("got %v", err)
	}

	redirect := httptest.NewServer(http.RedirectHandler(server.URL, http.StatusFound))
	defer redirect.Close()
	client, _ = NewHTTPClient(redirect.URL, "service-token", time.Second, 64*1024)
	if _, err := client.Introspect(context.Background(), "turn-grant"); !errors.Is(err, ErrUnexpectedResponse) {
		t.Fatalf("redirect got %v", err)
	}

	html := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<html>not json</html>"))
	}))
	defer html.Close()
	client, _ = NewHTTPClient(html.URL, "service-token", time.Second, 64*1024)
	if _, err := client.Introspect(context.Background(), "turn-grant"); !errors.Is(err, ErrUnexpectedResponse) {
		t.Fatalf("html got %v", err)
	}
}

func TestClientCapsResponsesAndHonorsCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/large" {
			_, _ = w.Write(make([]byte, 65))
			return
		}
		<-r.Context().Done()
	}))
	defer server.Close()

	client, _ := NewHTTPClient(server.URL, "service-token", 5*time.Second, 64)
	client.routes["get_validation_result"] = func(_, _ string) string { return "/large" }
	if _, err := client.Get(context.Background(), "turn-grant", "get_validation_result", "", "result"); !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("large got %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.Introspect(ctx, "turn-grant"); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation got %v", err)
	}
}
