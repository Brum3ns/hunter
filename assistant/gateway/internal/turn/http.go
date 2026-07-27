package turn

import (
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"sync/atomic"
	"time"
)

const maxRequestBytes = 64 << 10

type HandlerOptions struct {
	Processor      *Processor
	IngressToken   string
	AllowedHosts   []string
	AllowedOrigins []string
	MaxConcurrent  int
	Ready          *atomic.Bool
	Now            func() time.Time
}

type turnResponse struct {
	SchemaVersion int              `json:"schema_version"`
	CorrelationID string           `json:"correlation_id"`
	Events        []AssistantEvent `json:"events"`
}

// NewTurnHandler builds the authenticated POST /turns route: the checks run
// in a fixed order — method, host, origin, bearer token, readiness,
// saturation, then body — so that an unauthenticated or disallowed request
// is rejected before it can consume a concurrency slot or be parsed.
func NewTurnHandler(opts HandlerOptions) http.Handler {
	// Built once, not per request: a channel created inside the handler
	// closure would give every request its own fresh semaphore, and the
	// concurrency limit would never actually apply.
	slots := make(chan struct{}, max(opts.MaxConcurrent, 1))
	now := time.Now
	if opts.Now != nil {
		now = opts.Now
	}

	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost {
			writeCode(response, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		if !slices.Contains(opts.AllowedHosts, request.Host) {
			writeCode(response, http.StatusForbidden, "host_not_allowed")
			return
		}
		if origin := request.Header.Get("Origin"); origin != "" && !slices.Contains(opts.AllowedOrigins, origin) {
			writeCode(response, http.StatusForbidden, "origin_not_allowed")
			return
		}
		// ConstantTimeCompare, not ==: this is a bearer-token comparison, and a
		// timing side channel on it would leak the token one byte at a time.
		presented := strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(presented), []byte(opts.IngressToken)) != 1 {
			writeCode(response, http.StatusUnauthorized, "unauthorized")
			return
		}
		if opts.Ready != nil && !opts.Ready.Load() {
			writeCode(response, http.StatusServiceUnavailable, "gateway_not_ready")
			return
		}

		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			writeCode(response, http.StatusServiceUnavailable, "gateway_saturated")
			return
		}

		payload, err := io.ReadAll(io.LimitReader(request.Body, maxRequestBytes+1))
		if err != nil || len(payload) > maxRequestBytes {
			writeCode(response, http.StatusBadRequest, "invalid_envelope")
			return
		}
		job, err := DecodeTurnJob(payload, now())
		if err != nil {
			writeCode(response, http.StatusBadRequest, "invalid_envelope")
			return
		}

		// Process derives its own deadline from job.ExpiresAt capped by
		// maxTurnDuration, so the handler adds no deadline of its own.
		events := opts.Processor.Process(request.Context(), job)
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(response).Encode(turnResponse{
			SchemaVersion: 1, CorrelationID: job.CorrelationID, Events: events,
		})
	})
}

func writeCode(response http.ResponseWriter, status int, code string) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(map[string]any{"error": map[string]string{"code": code}})
}
