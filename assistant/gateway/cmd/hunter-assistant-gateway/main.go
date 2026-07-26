package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"hunter.local/assistant/gateway/internal/config"
	mcpclient "hunter.local/assistant/gateway/internal/mcp"
	"hunter.local/assistant/gateway/internal/provider"
	"hunter.local/assistant/gateway/internal/queue"
)

const healthAddress = "0.0.0.0:8081"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "-healthcheck" {
		if err := checkHealth(); err != nil {
			os.Exit(1)
		}
		return
	}

	settings, err := config.Load()
	if err != nil {
		log.Fatal("assistant gateway configuration rejected")
	}
	openAIKey, err := settings.ProviderSecrets.Resolve("openai_primary")
	if err != nil {
		log.Fatal("OpenAI credential unavailable")
	}
	anthropicKey, err := settings.ProviderSecrets.Resolve("anthropic_primary")
	if err != nil {
		log.Fatal("Anthropic credential unavailable")
	}
	providerClient, err := provider.NewRestrictedHTTPClient()
	if err != nil {
		log.Fatal("provider transport configuration rejected")
	}
	mcpClient, err := mcpclient.New(settings.GatewayMCPToken)
	if err != nil {
		log.Fatal("MCP client configuration rejected")
	}
	gateway := provider.NewGateway(
		provider.NewOpenAIAdapter(openAIKey, providerClient),
		provider.NewAnthropicAdapter(anthropicKey, providerClient),
	)
	processor := &queue.Processor{Gateway: gateway, Connect: queue.ConnectMCP(mcpClient)}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	var ready atomic.Bool
	healthServer := &http.Server{
		Addr: healthAddress, Handler: newHealthHandler(&ready),
		ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 2 * time.Second,
		WriteTimeout: 2 * time.Second, IdleTimeout: 5 * time.Second,
		MaxHeaderBytes: 4 << 10,
	}
	go func() {
		if err := healthServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			stop()
		}
	}()
	ready.Store(true)
	if err := queue.Run(ctx, settings.AMQPURL(), processor); err != nil && ctx.Err() == nil {
		ready.Store(false)
		log.Fatal("assistant gateway queue stopped")
	}
	ready.Store(false)
	shutdownContext, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = healthServer.Shutdown(shutdownContext)
}

func newHealthHandler(ready *atomic.Bool) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")
		if request.Method != http.MethodGet {
			response.Header().Set("Allow", http.MethodGet)
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !ready.Load() {
			response.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		response.WriteHeader(http.StatusNoContent)
	})
	return mux
}

func checkHealth() error {
	client := &http.Client{
		Timeout:       2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Get("http://127.0.0.1:8081/healthz")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("unhealthy")
	}
	return nil
}
