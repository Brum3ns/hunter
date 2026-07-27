package turn

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hunter.local/assistant/gateway/internal/provider"
)

const (
	testHost   = "assistant-gateway:8081"
	testOrigin = "https://hunter.test"
)

type stubGenerator struct{}

func (stubGenerator) Handle(context.Context, string, provider.Request, provider.ToolExecutor) provider.HandleEvent {
	return provider.HandleEvent{Result: &provider.Result{
		Envelope: provider.Envelope{Kind: "assistant_message", Body: "hello"},
		Usage:    provider.Usage{InputTokens: 1, OutputTokens: 1},
	}}
}

// blockingGenerator parks inside Handle until release is closed, which is what
// lets the saturation test hold concurrency slots open for as long as it needs
// them. It reports each arrival on entered so the test can wait for the slots
// to actually be occupied instead of sleeping and hoping.
type blockingGenerator struct {
	entered chan struct{}
	release chan struct{}
}

func (generator blockingGenerator) Handle(context.Context, string, provider.Request, provider.ToolExecutor) provider.HandleEvent {
	generator.entered <- struct{}{}
	<-generator.release
	return provider.HandleEvent{Result: &provider.Result{
		Envelope: provider.Envelope{Kind: "assistant_message", Body: "hello"},
		Usage:    provider.Usage{InputTokens: 1, OutputTokens: 1},
	}}
}

type stubToolSession struct{}

func (stubToolSession) Call(context.Context, string, []byte) ([]byte, error) { return nil, nil }
func (stubToolSession) Close() error                                         { return nil }

func stubConnect(context.Context, string) (ToolSession, error) {
	return stubToolSession{}, nil
}

// newHandler is the one place handler options are assembled for tests, so a
// case can vary exactly the one thing it is about — readiness, the generator,
// the slot count — and inherit everything else.
func newHandler(t *testing.T, ingressToken string, isReady bool, maxConcurrent int, generator Generator) http.Handler {
	t.Helper()
	var ready atomic.Bool
	ready.Store(isReady)
	return NewTurnHandler(HandlerOptions{
		Processor:      &Processor{Gateway: generator, Connect: stubConnect},
		IngressToken:   ingressToken,
		AllowedHosts:   []string{testHost},
		AllowedOrigins: []string{testOrigin},
		MaxConcurrent:  maxConcurrent,
		Ready:          &ready,
		Now:            time.Now,
	})
}

func newTestHandler(t *testing.T, ingressToken string) http.Handler {
	t.Helper()
	return newHandler(t, ingressToken, true, 2, stubGenerator{})
}

// newNotReadyTestHandler mirrors newTestHandler but with ready=false, for the
// 503-not-ready case.
func newNotReadyTestHandler(t *testing.T, ingressToken string) http.Handler {
	t.Helper()
	return newHandler(t, ingressToken, false, 2, stubGenerator{})
}

func validEnvelopeJSON(t *testing.T) string {
	t.Helper()
	return string(validTurnJob(t))
}

// paddedTurnJob builds an otherwise valid envelope whose user_message is
// userMessageBytes long and which carries referenceCount maximum-length
// context references, so a case can land either side of a size bound.
func paddedTurnJob(t *testing.T, userMessageBytes, referenceCount int) []byte {
	t.Helper()
	references := make([]any, 0, referenceCount)
	for range referenceCount {
		references = append(references, map[string]any{
			"type": "target", "id": strings.Repeat("i", 255),
			"label": strings.Repeat("l", 255), "serializer_version": "v1",
		})
	}
	payload := map[string]any{
		"schema_version": 1,
		"correlation_id": "b3a7e1a2-34ab-4aa1-8fc0-5f507a33d1af",
		"turn_id":        1, "conversation_id": 2, "user_id": 3,
		"provider_profile": map[string]any{
			"profile_id": 4, "catalog_slug": "openai_primary", "provider": "openai",
			"model": "gpt-5", "secret_ref": "openai_primary", "input_limit": 4096,
			"output_limit": 2048, "tool_call_limit": 8, "retention_posture": "standard",
			"reviewed_at": time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
		},
		"user_message":       strings.Repeat("a", userMessageBytes),
		"context_references": references,
		"turn_grant":         strings.Repeat("g", 32),
		"expires_at":         time.Now().Add(time.Minute).UTC().Format(time.RFC3339),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func newTurnRequest(t *testing.T, body string) *http.Request {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(body))
	request.Host = testHost
	request.Header.Set("Authorization", "Bearer secret-token")
	return request
}

// assertErrorCode pins both halves of the failure contract: the status and
// the error code inside the JSON envelope. Asserting only the status would let
// two different 403s or 503s be swapped without any test noticing.
func assertErrorCode(t *testing.T, recorder *httptest.ResponseRecorder, wantStatus int, wantCode string) {
	t.Helper()
	if recorder.Code != wantStatus {
		t.Fatalf("status = %d, want %d: %s", recorder.Code, wantStatus, recorder.Body.String())
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode %q: %v", recorder.Body.String(), err)
	}
	if body.Error.Code != wantCode {
		t.Fatalf("error code = %q, want %q", body.Error.Code, wantCode)
	}
}

func TestTurnHandlerRejectsMissingBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = testHost
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", recorder.Code)
	}
}

// A missing Authorization header never reaches the constant-time compare, so
// a wrong-but-present token is a separate case: it is the one that proves the
// comparison itself rejects rather than merely that the header is required.
func TestTurnHandlerRejectsWrongBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	for name, presented := range map[string]string{
		"wrong token":      "Bearer wrong-token",
		"correct prefix":   "Bearer secret-toke",
		"extra suffix":     "Bearer secret-tokenn",
		"missing scheme":   "secret-token",
		"empty after Bear": "Bearer ",
	} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
			request.Host = testHost
			request.Header.Set("Authorization", presented)
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, request)

			assertErrorCode(t, recorder, http.StatusUnauthorized, "unauthorized")
		})
	}
}

func TestTurnHandlerRejectsUnknownHost(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "evil.example.com"
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", recorder.Code)
	}
}

// The check order is part of the contract, not an implementation detail: host
// filtering must run before authentication so an off-allowlist caller is
// turned away without its token ever being compared. A request that fails
// both checks at once is the only thing that can detect a reordering.
func TestTurnHandlerChecksHostBeforeBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "evil.example.com"
	request.Header.Set("Authorization", "Bearer wrong-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusForbidden, "host_not_allowed")
}

// Likewise the method check precedes the host check, so a GET from an
// off-allowlist host reports the method rather than the host.
func TestTurnHandlerChecksMethodBeforeHost(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodGet, "/turns", nil)
	request.Host = "evil.example.com"
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusMethodNotAllowed, "method_not_allowed")
}

func TestTurnHandlerRejectsNonPostMethods(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch, http.MethodHead} {
		t.Run(method, func(t *testing.T) {
			request := httptest.NewRequest(method, "/turns", nil)
			request.Host = testHost
			request.Header.Set("Authorization", "Bearer secret-token")
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusMethodNotAllowed {
				t.Fatalf("status = %d, want 405", recorder.Code)
			}
		})
	}
}

func TestTurnHandlerRejectsDisallowedOrigin(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := newTurnRequest(t, validEnvelopeJSON(t))
	request.Header.Set("Origin", "https://evil.example.com")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusForbidden, "origin_not_allowed")
}

func TestTurnHandlerAcceptsAllowedOrigin(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := newTurnRequest(t, validEnvelopeJSON(t))
	request.Header.Set("Origin", testOrigin)
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
}

func TestTurnHandlerRejectsMalformedAndOversizedBodies(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	for name, body := range map[string]string{
		"not JSON at all":     "this is not JSON",
		"truncated JSON":      `{"schema_version":1,`,
		"empty body":          "",
		"JSON but not a job":  `{"unexpected":true}`,
		"beyond maxJobBytes":  string(paddedTurnJob(t, 200_000, 0)),
		"beyond user_message": string(paddedTurnJob(t, (64<<10)+1, 0)),
	} {
		t.Run(name, func(t *testing.T) {
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, newTurnRequest(t, body))

			assertErrorCode(t, recorder, http.StatusBadRequest, "invalid_envelope")
		})
	}
}

// A maximum-length user_message plus a full set of context references is a
// legitimate envelope that comfortably exceeds 64KiB. The HTTP body cap must
// therefore be the same bound DecodeTurnJob applies, not a tighter one, or
// real turns are rejected as invalid_envelope before the decoder sees them.
func TestTurnHandlerAcceptsALegitimateEnvelopeLargerThan64KiB(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	body := paddedTurnJob(t, 64<<10, 10)
	if len(body) <= 64<<10 {
		t.Fatalf("precondition: body is %d bytes, expected more than %d", len(body), 64<<10)
	}
	if len(body) > maxJobBytes {
		t.Fatalf("precondition: body is %d bytes, expected no more than maxJobBytes=%d", len(body), maxJobBytes)
	}
	if _, err := DecodeTurnJob(body, time.Now()); err != nil {
		t.Fatalf("precondition: DecodeTurnJob rejected the envelope: %v", err)
	}
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, newTurnRequest(t, string(body)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 for a %d-byte envelope: %s", recorder.Code, len(body), recorder.Body.String())
	}
}

func TestTurnHandlerReturnsEventsWithoutProgressKind(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = testHost
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		SchemaVersion int                     `json:"schema_version"`
		CorrelationID string                  `json:"correlation_id"`
		Events        []struct{ Kind string } `json:"events"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.SchemaVersion != 1 {
		t.Fatalf("schema_version = %d, want 1", body.SchemaVersion)
	}
	if body.CorrelationID != "b3a7e1a2-34ab-4aa1-8fc0-5f507a33d1af" {
		t.Fatalf("correlation_id = %q", body.CorrelationID)
	}
	for _, event := range body.Events {
		if event.Kind == "progress" {
			t.Fatal("progress events must no longer be emitted")
		}
	}
}

func TestTurnHandlerReturns503WhenNotReady(t *testing.T) {
	handler := newNotReadyTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = testHost
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusServiceUnavailable, "gateway_not_ready")
}

// The idle gateway mounts /turns with a nil Processor. That must answer with
// the documented envelope rather than panicking, whatever Ready says — so this
// case deliberately sets ready=true, which is the state a nil-check placed
// after the Ready gate would fall straight through.
func TestTurnHandlerWithNilProcessorReportsNotReady(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	handler := NewTurnHandler(HandlerOptions{
		Processor:      nil,
		IngressToken:   "secret-token",
		AllowedHosts:   []string{testHost},
		AllowedOrigins: []string{testOrigin},
		MaxConcurrent:  2,
		Ready:          &ready,
	})
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, newTurnRequest(t, validEnvelopeJSON(t)))

	assertErrorCode(t, recorder, http.StatusServiceUnavailable, "gateway_not_ready")
}

// A nil Ready must not panic either; with a processor present it simply means
// "no readiness gate".
func TestTurnHandlerToleratesNilReady(t *testing.T) {
	handler := NewTurnHandler(HandlerOptions{
		Processor:      &Processor{Gateway: stubGenerator{}, Connect: stubConnect},
		IngressToken:   "secret-token",
		AllowedHosts:   []string{testHost},
		AllowedOrigins: []string{testOrigin},
		MaxConcurrent:  2,
	})
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, newTurnRequest(t, validEnvelopeJSON(t)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
}

// Real concurrency, not a simulated counter: two turns are held inside the
// generator so both slots are genuinely occupied, and only then is a third
// request made. A semaphore built per request — or one whose slot is never
// released — cannot pass both halves of this test.
func TestTurnHandlerReturns503WhenSaturated(t *testing.T) {
	generator := blockingGenerator{entered: make(chan struct{}, 2), release: make(chan struct{})}
	handler := newHandler(t, "secret-token", true, 2, generator)

	inFlight := make(chan int, 2)
	for range 2 {
		go func() {
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, newTurnRequest(t, validEnvelopeJSON(t)))
			inFlight <- recorder.Code
		}()
	}
	// Wait for both turns to be inside the generator, so the slots are held.
	for range 2 {
		select {
		case <-generator.entered:
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for the in-flight turns to occupy their slots")
		}
	}

	// Served on its own goroutine with a deadline, not inline: a per-request
	// semaphore would hand this request a fresh empty slot, let it into the
	// blocked generator and hang the test until the whole suite times out.
	// Bounding it turns that into a fast, legible failure.
	saturated := httptest.NewRecorder()
	rejected := make(chan struct{})
	go func() {
		handler.ServeHTTP(saturated, newTurnRequest(t, validEnvelopeJSON(t)))
		close(rejected)
	}()
	select {
	case <-rejected:
	case <-time.After(5 * time.Second):
		t.Fatal("a request beyond the concurrency limit was admitted instead of being rejected; the slot semaphore is not shared across requests")
	}
	assertErrorCode(t, saturated, http.StatusServiceUnavailable, "gateway_saturated")

	close(generator.release)
	for range 2 {
		select {
		case code := <-inFlight:
			if code != http.StatusOK {
				t.Fatalf("in-flight turn status = %d, want 200", code)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for the in-flight turns to finish")
		}
	}

	// Every slot must have been handed back, or the gateway would stay
	// saturated forever after its first burst.
	afterRelease := httptest.NewRecorder()
	handler.ServeHTTP(afterRelease, newTurnRequest(t, validEnvelopeJSON(t)))
	if afterRelease.Code != http.StatusOK {
		t.Fatalf("status after release = %d, want 200: %s", afterRelease.Code, afterRelease.Body.String())
	}
}

// A rejected request must not consume a slot: authentication and the other
// pre-slot checks run first precisely so a flood of unauthorized calls cannot
// saturate the gateway.
func TestTurnHandlerRejectedRequestsDoNotConsumeSlots(t *testing.T) {
	handler := newHandler(t, "secret-token", true, 1, stubGenerator{})

	for range 5 {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
		request.Host = testHost
		request.Header.Set("Authorization", "Bearer wrong-token")
		handler.ServeHTTP(recorder, request)
		assertErrorCode(t, recorder, http.StatusUnauthorized, "unauthorized")
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, newTurnRequest(t, validEnvelopeJSON(t)))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
}
