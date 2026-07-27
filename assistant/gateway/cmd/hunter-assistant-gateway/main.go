package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"hunter.local/assistant/gateway/internal/config"
	mcpclient "hunter.local/assistant/gateway/internal/mcp"
	"hunter.local/assistant/gateway/internal/provider"
	"hunter.local/assistant/gateway/internal/turn"
)

const listenAddress = "0.0.0.0:8081"

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
	// One mux serves both routes so the process needs only one listening
	// socket. /healthz is registered immediately so the idle path below can
	// still answer health checks; /turns is added later, once a processor
	// exists — http.ServeMux.Handle is safe to call while the server is
	// already serving, since registration is guarded by the mux's own lock.
	mux := http.NewServeMux()
	mux.Handle("/healthz", newHealthHandler(&ready))
	// ReadTimeout/WriteTimeout must cover a full turn: the grant TTL is 300s,
	// so 310s leaves margin. ReadHeaderTimeout and MaxHeaderBytes stay tight —
	// they are the slow-loris defence, and a turn's headers are tiny
	// regardless of how long its body takes to arrive or its response takes
	// to produce.
	turnServer := &http.Server{
		Addr: listenAddress, Handler: mux,
		ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 310 * time.Second,
		WriteTimeout: 310 * time.Second, IdleTimeout: 5 * time.Second,
		MaxHeaderBytes: 4 << 10,
	}
	go func() {
		if err := turnServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
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
		blockUntilShutdown(ctx, turnServer)
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
	processor := &turn.Processor{Gateway: gateway, Connect: turn.ConnectMCP(mcpClient)}

	mux.Handle("/turns", turn.NewTurnHandler(turn.HandlerOptions{
		Processor:      processor,
		IngressToken:   settings.IngressToken,
		AllowedHosts:   splitList(os.Getenv("ASSISTANT_GATEWAY_ALLOWED_HOSTS")),
		AllowedOrigins: splitList(os.Getenv("ASSISTANT_GATEWAY_ALLOWED_ORIGINS")),
		MaxConcurrent:  intFromEnv("ASSISTANT_MAX_CONCURRENT_TURNS", 2),
		Ready:          &ready,
	}))
	ready.Store(true)
	blockUntilShutdown(ctx, turnServer)
}

// resolveAdapters builds an adapter for each profile the config preflight
// reported available, dropping any whose value the stricter runtime read
// rejects, and returns the profiles that actually ended up usable.
//
// The preflight (config.ProviderStatus) and the runtime read
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

// blockUntilShutdown blocks until the signal context is cancelled, then
// shuts turnServer down. Serving itself already happens in the background
// goroutine started around ListenAndServe, so this is just what keeps main
// from returning early: the idle path calls it with only /healthz mounted
// (ready is never stored true, so it keeps reporting 503 the whole time),
// and the ready path calls it once /turns is mounted too.
func blockUntilShutdown(ctx context.Context, turnServer *http.Server) {
	<-ctx.Done()
	shutdownContext, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = turnServer.Shutdown(shutdownContext)
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

// splitList parses a comma-separated environment value into its trimmed,
// non-empty entries. An empty or all-blank input yields an empty slice, not
// a slice holding one empty string, so an unset allowlist denies everything
// instead of accidentally matching an empty Host or Origin.
func splitList(value string) []string {
	if value == "" {
		return nil
	}
	fields := strings.Split(value, ",")
	list := make([]string, 0, len(fields))
	for _, field := range fields {
		if trimmed := strings.TrimSpace(field); trimmed != "" {
			list = append(list, trimmed)
		}
	}
	return list
}

// intFromEnv reads a positive integer environment variable, falling back to
// fallback when it is unset, empty, or fails to parse as one.
func intFromEnv(name string, fallback int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 {
		return fallback
	}
	return value
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
