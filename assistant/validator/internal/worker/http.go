package worker

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

// maxRequestBytes is the HTTP body cap. It is defined as maxJobBytes rather
// than as an independent number so the transport can never reject a body that
// DecodeJob would have accepted: source alone is bounded at 64KiB and the
// envelope carries several further fields on top of it, so referencing the
// constant is what keeps the two bounds from drifting apart.
const maxRequestBytes = maxJobBytes

type HandlerOptions struct {
	Processor      Processor
	IngressToken   string
	AllowedHosts   []string
	AllowedOrigins []string
	MaxConcurrent  int
	Ready          *atomic.Bool
	Now            func() time.Time
}

type validationResponse struct {
	SchemaVersion int   `json:"schema_version"`
	Event         Event `json:"event"`
}

// NewValidationHandler builds the authenticated POST /validations route: the
// checks run in a fixed order — method, host, origin, bearer token,
// readiness, saturation, then body — so that an unauthenticated or
// disallowed request is rejected before it can consume a concurrency slot or
// be parsed.
func NewValidationHandler(opts HandlerOptions) http.Handler {
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
		// CutPrefix, not TrimPrefix: TrimPrefix returns the header unchanged when
		// the scheme is absent, which would accept a bare "Authorization: <token>"
		// as though it were "Bearer <token>". Requiring the scheme keeps the
		// accepted form to exactly the one Rails sends.
		//
		// ConstantTimeCompare, not ==: this is a bearer-token comparison, and a
		// timing side channel on it would leak the token one byte at a time. The
		// short-circuit on a missing scheme is not such a channel — it reveals
		// only whether the caller sent a scheme, which the caller already knows.
		presented, hasScheme := strings.CutPrefix(request.Header.Get("Authorization"), "Bearer ")
		if !hasScheme || subtle.ConstantTimeCompare([]byte(presented), []byte(opts.IngressToken)) != 1 {
			writeCode(response, http.StatusUnauthorized, "unauthorized")
			return
		}
		// The validator holds no provider credential and has no idle mode of its
		// own, so unlike the gateway there is no nil-Processor signal to check
		// here: Processor is a value (Process has a value receiver), and a zero
		// value with a nil Checker already answers "failed" rather than
		// panicking. Readiness is therefore the only gate left to check.
		if opts.Ready != nil && !opts.Ready.Load() {
			writeCode(response, http.StatusServiceUnavailable, "validator_not_ready")
			return
		}

		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			writeCode(response, http.StatusServiceUnavailable, "validator_saturated")
			return
		}

		payload, err := io.ReadAll(io.LimitReader(request.Body, maxRequestBytes+1))
		if err != nil || len(payload) > maxRequestBytes {
			writeCode(response, http.StatusBadRequest, "invalid_envelope")
			return
		}
		job, err := DecodeJob(payload, now())
		if err != nil {
			writeCode(response, http.StatusBadRequest, "invalid_envelope")
			return
		}

		// Process derives its own deadline from job.ExpiresAt capped by
		// maxValidationDuration, so the handler adds no deadline of its own.
		event := opts.Processor.Process(request.Context(), job)
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(response).Encode(validationResponse{SchemaVersion: 1, Event: event})
	})
}

func writeCode(response http.ResponseWriter, status int, code string) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(map[string]any{"error": map[string]string{"code": code}})
}
