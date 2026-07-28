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

	"hunter.local/assistant/validator/internal/check"
	"hunter.local/assistant/validator/internal/config"
	"hunter.local/assistant/validator/internal/worker"
)

const listenAddress = "0.0.0.0:8082"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "-healthcheck" {
		if err := checkHealth(); err != nil {
			os.Exit(1)
		}
		return
	}

	settings, err := config.Load()
	if err != nil {
		log.Fatal("assistant validator configuration rejected")
	}
	processor := worker.Processor{Checker: check.Checker{WorkRoot: "/work"}}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	var ready atomic.Bool

	// ReadTimeout/WriteTimeout must cover a full validation: the job TTL is
	// 5 minutes, so 310s leaves margin. ReadHeaderTimeout and MaxHeaderBytes
	// stay tight — they are the slow-loris defence, and a validation's headers
	// are tiny regardless of how long its body takes to arrive or its
	// response takes to produce.
	validationServer := &http.Server{
		Addr: listenAddress, Handler: newServeMux(&ready, processor, settings.IngressToken),
		ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 310 * time.Second,
		WriteTimeout: 310 * time.Second, IdleTimeout: 5 * time.Second,
		MaxHeaderBytes: 4 << 10,
	}
	go func() {
		if err := validationServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			stop()
		}
	}()

	ready.Store(true)
	blockUntilShutdown(ctx, &ready, validationServer)
}

// newServeMux builds the one mux the process serves. It is fully populated
// before the server starts listening; nothing is registered on it afterwards.
func newServeMux(ready *atomic.Bool, processor worker.Processor, ingressToken string) *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("/healthz", newHealthHandler(ready))
	mux.Handle("/validations", worker.NewValidationHandler(worker.HandlerOptions{
		Processor:      processor,
		IngressToken:   ingressToken,
		AllowedHosts:   splitList(os.Getenv("ASSISTANT_VALIDATOR_ALLOWED_HOSTS")),
		AllowedOrigins: splitList(os.Getenv("ASSISTANT_VALIDATOR_ALLOWED_ORIGINS")),
		MaxConcurrent:  intFromEnv("ASSISTANT_MAX_CONCURRENT_VALIDATIONS", 2),
		Ready:          ready,
	}))
	return mux
}

// blockUntilShutdown blocks until the signal context is cancelled, then marks
// the validator unready and shuts validationServer down. Serving itself
// already happens in the background goroutine around ListenAndServe, so this
// is just what keeps main from returning early. Clearing ready first means
// any request racing the shutdown gets 503 rather than being handed to a
// processor whose process is on its way out.
func blockUntilShutdown(ctx context.Context, ready *atomic.Bool, validationServer *http.Server) {
	<-ctx.Done()
	ready.Store(false)
	shutdownContext, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = validationServer.Shutdown(shutdownContext)
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
	response, err := client.Get("http://127.0.0.1:8082/healthz")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("unhealthy")
	}
	return nil
}
