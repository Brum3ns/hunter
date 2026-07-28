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

// maxRequestBytes is the HTTP body cap. It is defined as maxJobBytes rather
// than as an independent number so the transport can never reject a body that
// DecodeTurnJob would have accepted: user_message alone is bounded at 64KiB,
// and the envelope carries a turn grant, up to ten context references and
// nine further fields on top of it, so a legitimate maximum-size turn already
// exceeds 64KiB — by more still once the message holds multibyte UTF-8.
// Referencing the constant is what keeps the two bounds from drifting apart.
const maxRequestBytes = maxJobBytes

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
		// A nil Processor is the idle gateway: the route is mounted so this
		// answers with the documented envelope, but there is nothing behind it.
		// Checked alongside Ready — never after it — so the nil is impossible to
		// reach at the Process call below whatever Ready happens to say.
		if opts.Processor == nil || (opts.Ready != nil && !opts.Ready.Load()) {
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
