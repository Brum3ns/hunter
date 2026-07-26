package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"strings"
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

	if len(settings.AvailableProfiles) == 0 {
		log.Print("assistant gateway idle: no provider credentials installed")
		serveHealthOnly(ctx, healthServer)
		return
	}
	log.Printf("assistant gateway ready: profiles=%s", strings.Join(settings.AvailableProfiles, ","))

	providerClient, err := provider.NewRestrictedHTTPClient()
	if err != nil {
		log.Fatal("provider transport configuration rejected")
	}

	var openAIAdapter provider.Adapter
	if slices.Contains(settings.AvailableProfiles, "openai_primary") {
		openAIKey, err := settings.ProviderSecrets.Resolve("openai_primary")
		if err != nil {
			log.Fatal("OpenAI credential unavailable")
		}
		openAIAdapter = provider.NewOpenAIAdapter(openAIKey, providerClient)
	}
	var anthropicAdapter provider.Adapter
	if slices.Contains(settings.AvailableProfiles, "anthropic_primary") {
		anthropicKey, err := settings.ProviderSecrets.Resolve("anthropic_primary")
		if err != nil {
			log.Fatal("Anthropic credential unavailable")
		}
		anthropicAdapter = provider.NewAnthropicAdapter(anthropicKey, providerClient)
	}

	mcpClient, err := mcpclient.New(settings.GatewayMCPToken)
	if err != nil {
		log.Fatal("MCP client configuration rejected")
	}
	// A profile not present in AvailableProfiles maps to a nil entry in this
	// gateway's adapter table. Gateway.Handle checks for that nil explicitly
	// and returns the stable "provider_not_allowed" event rather than
	// dereferencing it, so a turn naming an unconfigured provider terminates
	// cleanly instead of panicking.
	gateway := provider.NewGateway(openAIAdapter, anthropicAdapter)
	processor := &queue.Processor{Gateway: gateway, Connect: queue.ConnectMCP(mcpClient)}

	ready.Store(true)
	if err := queue.Run(ctx, settings.AMQPURL(), processor); err != nil && ctx.Err() == nil {
		ready.Store(false)
		log.Fatal("assistant gateway queue stopped")
	}
	ready.Store(false)
	shutdownHealthServer(healthServer)
}

// serveHealthOnly is the idle path: no provider credential is installed, so
// the gateway never opens the AMQP consumer and never calls queue.Run. It
// blocks until the signal context is cancelled — /healthz keeps reporting 503
// the whole time, because ready is never stored true — then shuts the health
// server down through the same path the ready branch uses.
func serveHealthOnly(ctx context.Context, healthServer *http.Server) {
	<-ctx.Done()
	shutdownHealthServer(healthServer)
}

func shutdownHealthServer(healthServer *http.Server) {
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
