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

	"hunter.local/assistant/validator/internal/check"
	"hunter.local/assistant/validator/internal/config"
	"hunter.local/assistant/validator/internal/worker"
)

const healthAddress = "0.0.0.0:8082"

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
	healthServer := &http.Server{
		Addr:              healthAddress,
		Handler:           newHealthHandler(&ready),
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       2 * time.Second,
		WriteTimeout:      2 * time.Second,
		IdleTimeout:       5 * time.Second,
		MaxHeaderBytes:    4 << 10,
	}
	go func() {
		if serveErr := healthServer.ListenAndServe(); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			stop()
		}
	}()

	ready.Store(true)
	if runErr := worker.Run(ctx, settings.AMQPURL(), processor); runErr != nil && ctx.Err() == nil {
		ready.Store(false)
		log.Fatal("assistant validator queue stopped")
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
