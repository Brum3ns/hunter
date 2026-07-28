package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"hunter.local/assistant/mcp/internal/auth"
	"hunter.local/assistant/mcp/internal/config"
	artifacts "hunter.local/assistant/mcp/internal/modules/artifacts"
	contextmod "hunter.local/assistant/mcp/internal/modules/context"
	policies "hunter.local/assistant/mcp/internal/modules/policies"
	validation "hunter.local/assistant/mcp/internal/modules/validation"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/runner"
	"hunter.local/assistant/mcp/internal/transport"
)

const healthURL = "http://127.0.0.1:8080/healthz"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "-healthcheck" {
		if err := checkHealth(); err != nil {
			os.Exit(1)
		}
		return
	}

	settings, err := config.Load()
	if err != nil {
		log.Fatal("hunter-mcp configuration rejected")
	}
	transportClient, err := transport.NewClient(
		settings.HunterBaseURL,
		settings.HunterServiceToken,
		settings.RequestTimeout,
		settings.MaxResponseBytes,
	)
	if err != nil {
		log.Fatal("hunter-mcp client configuration rejected")
	}

	registry := runner.NewRegistry()
	registry.Add(
		contextmod.Module{},
		artifacts.Module{},
		policies.Module{},
		validation.Module{},
	)
	run := runner.New(transportClient, registry, redact.NewChecker(int(settings.MaxResponseBytes)))

	server := mcp.NewServer(
		&mcp.Implementation{Name: "hunter-mcp", Title: "Hunter Assistant MCP Broker", Version: "1.0.0"},
		&mcp.ServerOptions{Capabilities: &mcp.ServerCapabilities{}},
	)
	runner.Register(server, run)
	streamable := mcp.NewStreamableHTTPHandler(
		func(*http.Request) *mcp.Server { return server },
		&mcp.StreamableHTTPOptions{
			Stateless:      true,
			JSONResponse:   true,
			SessionTimeout: 30 * time.Second,
			// The outer middleware performs stricter exact Host and Origin checks
			// before the SDK. Keeping both protections enabled would reject a
			// legitimate loopback health/conformance proxy after Host validation.
			DisableLocalhostProtection: true,
		},
	)
	authenticator := auth.NewMiddleware(
		settings.GatewayToken,
		settings.AllowedHosts,
		settings.AllowedOrigins,
		settings.MaxRequestBytes,
	)

	httpServer := &http.Server{
		Addr:              settings.BindAddress,
		Handler:           newHTTPHandler(streamable, authenticator),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	shutdownContext, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdownContext.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
	}()

	log.Printf("hunter-mcp listening on %s", settings.BindAddress)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal("hunter-mcp server stopped unexpectedly")
	}
}

func newHTTPHandler(mcpHandler http.Handler, authenticator *auth.Middleware) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")
		if request.Method != http.MethodGet {
			response.Header().Set("Allow", http.MethodGet)
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		response.WriteHeader(http.StatusNoContent)
	})
	mux.Handle("/mcp", authenticator.Wrap(mcpHandler))
	return mux
}

func checkHealth() error {
	client := &http.Client{
		Timeout:       2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Get(healthURL)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("unhealthy")
	}
	return nil
}
