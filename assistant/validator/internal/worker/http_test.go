package worker

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hunter.local/assistant/validator/internal/check"
)

const (
	testHost   = "assistant-validator:8082"
	testOrigin = "https://hunter.test"
)

type stubChecker struct{}

func (stubChecker) Check(context.Context, string) check.Result {
	return check.Result{Status: "valid", Codes: []string{}}
}

// blockingChecker parks inside Check until release is closed, which is what
// lets the saturation test hold concurrency slots open for as long as it
// needs them. It reports each arrival on entered so the test can wait for the
// slots to actually be occupied instead of sleeping and hoping.
type blockingChecker struct {
	entered chan struct{}
	release chan struct{}
}

func (checker blockingChecker) Check(context.Context, string) check.Result {
	checker.entered <- struct{}{}
	<-checker.release
	return check.Result{Status: "valid", Codes: []string{}}
}

// newHandler is the one place handler options are assembled for tests, so a
// case can vary exactly the one thing it is about — readiness, the checker,
// the slot count — and inherit everything else.
func newHandler(t *testing.T, ingressToken string, isReady bool, maxConcurrent int, checker Checker) http.Handler {
	t.Helper()
	var ready atomic.Bool
	ready.Store(isReady)
	return NewValidationHandler(HandlerOptions{
		Processor:      Processor{Checker: checker},
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
	return newHandler(t, ingressToken, true, 2, stubChecker{})
}

// newNotReadyTestHandler mirrors newTestHandler but with ready=false, for the
// 503-not-ready case.
func newNotReadyTestHandler(t *testing.T, ingressToken string) http.Handler {
	t.Helper()
	return newHandler(t, ingressToken, false, 2, stubChecker{})
}

// validJobJSON builds an otherwise valid validation job envelope.
func validJobJSON(t *testing.T) string {
	t.Helper()
	now := time.Now().UTC()
	return string(encoded(t, validJob(now)))
}

// paddedJob builds an otherwise valid envelope whose source is sourceBytes
// long, so a case can land either side of a size bound.
func paddedJob(t *testing.T, sourceBytes int) []byte {
	t.Helper()
	now := time.Now().UTC()
	payload := validJob(now)
	payload["source"] = strings.Repeat("a", sourceBytes)
	return encoded(t, payload)
}

func newValidationRequest(t *testing.T, body string) *http.Request {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(body))
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

func TestValidationHandlerRejectsMissingBearer(t *testing.T) {
	handler := newTestHandler(t, "validator-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
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
func TestValidationHandlerRejectsWrongBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	for name, presented := range map[string]string{
		"wrong token":      "Bearer wrong-token",
		"correct prefix":   "Bearer secret-toke",
		"extra suffix":     "Bearer secret-tokenn",
		"missing scheme":   "secret-token",
		"empty after Bear": "Bearer ",
	} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
			request.Host = testHost
			request.Header.Set("Authorization", presented)
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, request)

			assertErrorCode(t, recorder, http.StatusUnauthorized, "unauthorized")
		})
	}
}

func TestValidationHandlerRejectsUnknownHost(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
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
func TestValidationHandlerChecksHostBeforeBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
	request.Host = "evil.example.com"
	request.Header.Set("Authorization", "Bearer wrong-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusForbidden, "host_not_allowed")
}

// Likewise the method check precedes the host check, so a GET from an
// off-allowlist host reports the method rather than the host.
func TestValidationHandlerChecksMethodBeforeHost(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodGet, "/validations", nil)
	request.Host = "evil.example.com"
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusMethodNotAllowed, "method_not_allowed")
}

func TestValidationHandlerRejectsNonPostMethods(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch, http.MethodHead} {
		t.Run(method, func(t *testing.T) {
			request := httptest.NewRequest(method, "/validations", nil)
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

func TestValidationHandlerRejectsDisallowedOrigin(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := newValidationRequest(t, validJobJSON(t))
	request.Header.Set("Origin", "https://evil.example.com")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusForbidden, "origin_not_allowed")
}

func TestValidationHandlerAcceptsAllowedOrigin(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := newValidationRequest(t, validJobJSON(t))
	request.Header.Set("Origin", testOrigin)
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
}

func TestValidationHandlerRejectsMalformedAndOversizedBodies(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	for name, body := range map[string]string{
		"not JSON at all":       "this is not JSON",
		"truncated JSON":        `{"schema_version":1,`,
		"empty body":            "",
		"JSON but not a job":    `{"unexpected":true}`,
		"beyond maxJobBytes":    string(paddedJob(t, 200_000)),
		"beyond source maximum": string(paddedJob(t, maxSourceBytes+1)),
	} {
		t.Run(name, func(t *testing.T) {
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, newValidationRequest(t, body))

			assertErrorCode(t, recorder, http.StatusBadRequest, "invalid_envelope")
		})
	}
}

// A maximum-length source is a legitimate envelope. The HTTP body cap must
// therefore be the same bound DecodeJob applies, not a tighter one, or a real
// validation job is rejected as invalid_envelope before the decoder sees it.
func TestValidationHandlerAcceptsALegitimateEnvelopeAtMaxSourceBytes(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	body := paddedJob(t, maxSourceBytes)
	if len(body) > maxJobBytes {
		t.Fatalf("precondition: body is %d bytes, expected no more than maxJobBytes=%d", len(body), maxJobBytes)
	}
	if _, err := DecodeJob(body, time.Now()); err != nil {
		t.Fatalf("precondition: DecodeJob rejected the envelope: %v", err)
	}
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, newValidationRequest(t, string(body)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 for a %d-byte envelope: %s", recorder.Code, len(body), recorder.Body.String())
	}
}

func TestValidationHandlerReturnsOneEvent(t *testing.T) {
	handler := newTestHandler(t, "validator-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
	request.Host = testHost
	request.Header.Set("Authorization", "Bearer validator-token")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		SchemaVersion int             `json:"schema_version"`
		Event         json.RawMessage `json:"event"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil || body.SchemaVersion != 1 || len(body.Event) == 0 {
		t.Fatalf("unexpected body: %s (%v)", recorder.Body.String(), err)
	}
	var event Event
	if err := json.Unmarshal(body.Event, &event); err != nil {
		t.Fatalf("decode event: %v", err)
	}
	if event.Status != "valid" || !uuidPattern.MatchString(event.EventID) {
		t.Fatalf("event = %+v", event)
	}
}

func TestValidationHandlerReturns503WhenNotReady(t *testing.T) {
	handler := newNotReadyTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
	request.Host = testHost
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	assertErrorCode(t, recorder, http.StatusServiceUnavailable, "validator_not_ready")
}

// A nil Ready must not panic; it simply means "no readiness gate".
func TestValidationHandlerToleratesNilReady(t *testing.T) {
	handler := NewValidationHandler(HandlerOptions{
		Processor:      Processor{Checker: stubChecker{}},
		IngressToken:   "secret-token",
		AllowedHosts:   []string{testHost},
		AllowedOrigins: []string{testOrigin},
		MaxConcurrent:  2,
	})
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, newValidationRequest(t, validJobJSON(t)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
}

// A zero-value Processor (nil Checker) must not panic either: Process
// already answers the documented "failed"/"validator_failed" event for a nil
// Checker, which the handler must simply pass through as a 200.
func TestValidationHandlerToleratesZeroValueProcessor(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	handler := NewValidationHandler(HandlerOptions{
		Processor:      Processor{},
		IngressToken:   "secret-token",
		AllowedHosts:   []string{testHost},
		AllowedOrigins: []string{testOrigin},
		MaxConcurrent:  2,
		Ready:          &ready,
	})
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, newValidationRequest(t, validJobJSON(t)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		Event Event `json:"event"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Event.Status != "failed" {
		t.Fatalf("event status = %q, want failed", body.Event.Status)
	}
}

// Real concurrency, not a simulated counter: two validations are held inside
// the checker so both slots are genuinely occupied, and only then is a third
// request made. A semaphore built per request — or one whose slot is never
// released — cannot pass both halves of this test.
func TestValidationHandlerReturns503WhenSaturated(t *testing.T) {
	checker := blockingChecker{entered: make(chan struct{}, 2), release: make(chan struct{})}
	handler := newHandler(t, "secret-token", true, 2, checker)

	inFlight := make(chan int, 2)
	for range 2 {
		go func() {
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, newValidationRequest(t, validJobJSON(t)))
			inFlight <- recorder.Code
		}()
	}
	// Wait for both validations to be inside the checker, so the slots are held.
	for range 2 {
		select {
		case <-checker.entered:
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for the in-flight validations to occupy their slots")
		}
	}

	// Served on its own goroutine with a deadline, not inline: a per-request
	// semaphore would hand this request a fresh empty slot, let it into the
	// blocked checker and hang the test until the whole suite times out.
	// Bounding it turns that into a fast, legible failure.
	saturated := httptest.NewRecorder()
	rejected := make(chan struct{})
	go func() {
		handler.ServeHTTP(saturated, newValidationRequest(t, validJobJSON(t)))
		close(rejected)
	}()
	select {
	case <-rejected:
	case <-time.After(5 * time.Second):
		t.Fatal("a request beyond the concurrency limit was admitted instead of being rejected; the slot semaphore is not shared across requests")
	}
	assertErrorCode(t, saturated, http.StatusServiceUnavailable, "validator_saturated")

	close(checker.release)
	for range 2 {
		select {
		case code := <-inFlight:
			if code != http.StatusOK {
				t.Fatalf("in-flight validation status = %d, want 200", code)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for the in-flight validations to finish")
		}
	}

	// Every slot must have been handed back, or the validator would stay
	// saturated forever after its first burst.
	afterRelease := httptest.NewRecorder()
	handler.ServeHTTP(afterRelease, newValidationRequest(t, validJobJSON(t)))
	if afterRelease.Code != http.StatusOK {
		t.Fatalf("status after release = %d, want 200: %s", afterRelease.Code, afterRelease.Body.String())
	}
}

// A rejected request must not consume a slot: authentication and the other
// pre-slot checks run first precisely so a flood of unauthorized calls cannot
// saturate the validator.
func TestValidationHandlerRejectedRequestsDoNotConsumeSlots(t *testing.T) {
	handler := newHandler(t, "secret-token", true, 1, stubChecker{})

	for range 5 {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
		request.Host = testHost
		request.Header.Set("Authorization", "Bearer wrong-token")
		handler.ServeHTTP(recorder, request)
		assertErrorCode(t, recorder, http.StatusUnauthorized, "unauthorized")
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, newValidationRequest(t, validJobJSON(t)))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
}

// TestIngressContractCases pins the shared behaviour of this handler against
// the gateway's: both read the same case table, substituting only their own
// host and token, so a divergence in either service's check order or error
// vocabulary fails both suites rather than silently drifting apart.
func TestIngressContractCases(t *testing.T) {
	raw, err := os.ReadFile("../../../contracts/v1/http_ingress_cases.json")
	if err != nil {
		t.Fatalf("read case table: %v", err)
	}
	var table struct {
		Cases []struct {
			Name, Authorization, Host, Origin string
			WantStatus                        int    `json:"want_status"`
			WantCode                          string `json:"want_code"`
		}
	}
	if err := json.Unmarshal(raw, &table); err != nil {
		t.Fatalf("decode case table: %v", err)
	}
	if len(table.Cases) == 0 {
		t.Fatal("case table is empty")
	}

	const validHost = "assistant-validator:8082" // gateway copy uses assistant-gateway:8081
	const validToken = "contract-token"

	for _, testCase := range table.Cases {
		t.Run(testCase.Name, func(t *testing.T) {
			handler := newTestHandler(t, validToken)
			request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
			request.Host = strings.ReplaceAll(testCase.Host, "VALID_HOST", validHost)
			if testCase.Authorization != "" {
				request.Header.Set("Authorization", strings.ReplaceAll(testCase.Authorization, "VALID_TOKEN", validToken))
			}
			if testCase.Origin != "" {
				request.Header.Set("Origin", testCase.Origin)
			}
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, request)

			if recorder.Code != testCase.WantStatus {
				t.Fatalf("status = %d, want %d: %s", recorder.Code, testCase.WantStatus, recorder.Body.String())
			}
			if testCase.WantCode == "" {
				return
			}
			var body struct {
				Error struct{ Code string } `json:"error"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode body: %v", err)
			}
			if body.Error.Code != testCase.WantCode {
				t.Fatalf("error.code = %q, want %q", body.Error.Code, testCase.WantCode)
			}
		})
	}
}
