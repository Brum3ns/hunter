package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
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

	var openAIAdapter, anthropicAdapter provider.Adapter
	var activeProfiles []string
	// Guarded so the zero-credential path never reaches
	// NewRestrictedHTTPClient, whose failure is fatal — idling must not be able
	// to exit through it.
	if len(settings.AvailableProfiles) > 0 {
		providerClient, err := provider.NewRestrictedHTTPClient()
		if err != nil {
			log.Fatal("provider transport configuration rejected")
		}
		openAIAdapter, anthropicAdapter, activeProfiles = resolveAdapters(settings, providerClient)
	}
	if len(activeProfiles) == 0 {
		log.Print("assistant gateway idle: no usable provider credential installed")
		serveHealthOnly(ctx, healthServer)
		return
	}
	log.Printf("assistant gateway ready: profiles=%s", strings.Join(activeProfiles, ","))

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

// resolveAdapters builds an adapter for each profile the config preflight
// reported available, dropping any whose value the stricter runtime read
// rejects, and returns the profiles that actually ended up usable.
//
// The preflight (config.ProviderStatusIn) and the runtime read
// (SecretResolver.Resolve) do not agree in every case, deliberately: the
// preflight mirrors Rails' ProviderCredentials so the chat and the gateway
// speak one reason vocabulary, while Resolve additionally rejects a value
// containing NUL, CR, LF, tab or a space. A key with an internal space
// therefore reports "valid" yet fails to resolve. That must disable the one
// provider, never exit the process: exiting would crash-loop the container
// under restart: unless-stopped, which is the exact failure this service was
// changed to eliminate. Only the profile slug is logged, never the value.
func resolveAdapters(settings config.Config, providerClient *http.Client) (provider.Adapter, provider.Adapter, []string) {
	var openAIAdapter, anthropicAdapter provider.Adapter
	active := make([]string, 0, len(settings.AvailableProfiles))
	for _, reference := range settings.AvailableProfiles {
		key, err := settings.ProviderSecrets.Resolve(reference)
		if err != nil {
			log.Printf("assistant gateway provider disabled: profile=%s reason=unusable_credential", reference)
			continue
		}
		switch reference {
		case "openai_primary":
			openAIAdapter = provider.NewOpenAIAdapter(key, providerClient)
		case "anthropic_primary":
			anthropicAdapter = provider.NewAnthropicAdapter(key, providerClient)
		default:
			log.Printf("assistant gateway provider disabled: profile=%s reason=unknown_profile", reference)
			continue
		}
		active = append(active, reference)
	}
	return openAIAdapter, anthropicAdapter, active
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
