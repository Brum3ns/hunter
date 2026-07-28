# Assistant Infrastructure Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove RabbitMQ, squid, the Rails event consumer and all three bootstrap one-shots by having Rails call the gateway and validator over HTTP, with every secret supplied as an environment variable.

**Architecture:** Rails answers the browser with `202` and runs the turn in a Solid Queue job that POSTs the existing turn envelope to the gateway and holds the connection; the gateway performs the provider call and MCP tool loop and returns an ordered array of the same assistant events it used to publish. Both Go services already run an HTTP server with `/healthz`, so this adds one authenticated route to each existing mux. The privilege separation is untouched — the gateway keeps no Hunter identity, MCP stays the only path to Hunter data.

**Tech Stack:** Ruby 3.3.6 / Rails 8 (Minitest, Solid Queue), Go 1.24 (stdlib `net/http`), Docker Compose.

**Spec:** [`docs/superpowers/specs/2026-07-27-assistant-infra-simplification-design.md`](../specs/2026-07-27-assistant-infra-simplification-design.md)

## Global Constraints

- Commit author `Claude <noreply@anthropic.com>`; commit messages are a single sentence, no body.
- Only commit when the user asks. Each task's final step stages and commits; batch-confirm with the user if they have not pre-authorised.
- Ruby tests: `bin/rails test` from `web/` (needs Postgres `hunter_test`). The standalone compose/contract suites run directly: `bundle exec ruby test/config/assistant_compose_test.rb`.
- Go tests: `go test ./...` from `assistant/gateway/` and `assistant/validator/`.
- Mongo is doubled in tests. After this change **no test may require a live RabbitMQ.**
- `Assistant::QueueContracts` keeps its name and its two public methods (`validate_turn_job!`, `validate_assistant_event!`). It is the envelope schema, not a queue binding.
- Secrets are declared per service under Compose `environment:` with `${VAR}` substitution. **Never add a secret to `env_file:`** — `runner` and `ansible-executor` load the whole `.env`.
- No service may mount `./secrets`; the `assistant_secrets` volume must not exist.
- Provider key values are never logged. Only profile slugs and reason codes.
- Tasks 1–5 leave both transports present so the stack boots throughout; deletion is concentrated in Tasks 6–7.

---

## File Structure

**Rails — `web/`**

| File | Responsibility after this change |
|---|---|
| `app/services/assistant/provider_credentials.rb` | Classify a provider key **env var** into a reason code |
| `app/services/assistant/activation.rb` | Derive activation; loses its `directory:` parameter |
| `app/services/assistant/provider_catalog.rb` | Expose `secret_env` instead of `secret_file` |
| `config/assistant_provider_catalog.yml` | `secret_env:` keys |
| `app/services/assistant/gateway_client.rb` | **new** — HTTP client for `POST /turns` |
| `app/services/assistant/validator_client.rb` | **new** — HTTP client for `POST /validations` |
| `app/jobs/assistant/turn_job.rb` | **new** — Solid Queue job: run turn, ingest events |
| `app/services/assistant/turn_dispatcher.rb` | Enqueue the job instead of publishing to AMQP |
| `app/services/assistant/validation_dispatcher.rb` | Call the validator client instead of publishing |
| `app/services/assistant/broker.rb` | **deleted** |
| `app/services/assistant/event_consumer.rb` | **deleted** |
| `app/services/assistant/bootstrap_service_token.rb` | **deleted** |
| `db/seeds.rb` | Upsert the `hunter-mcp` identity from env |

**Go — `assistant/gateway/`**

| File | Responsibility |
|---|---|
| `internal/turn/turn.go` | Renamed from `internal/queue/consumer.go`, AMQP funcs removed |
| `internal/turn/http.go` | **new** — `NewTurnHandler`, auth, saturation, encode |
| `internal/config/config.go` | Read secrets from env; delete file/mode machinery |
| `cmd/hunter-assistant-gateway/main.go` | Mount `/turns`; drop `queue.Run` |

**Go — `assistant/validator/`** mirrors the gateway: `internal/worker/worker.go` loses `Run`/`publishEvent`, gains `internal/worker/http.go`, `cmd` mounts `/validations`.

**Deleted outright:** `ops/assistant/provision_rabbitmq.rb`, `ops/assistant/bootstrap.sh`, `ops/assistant/bootstrap_service_token.rb`, `ops/assistant/rabbitmq/`, `assistant/egress/`.

---

### Task 1: Provider credentials from environment

**Files:**
- Modify: `web/config/assistant_provider_catalog.yml`
- Modify: `web/app/services/assistant/provider_catalog.rb`
- Modify: `web/app/services/assistant/provider_credentials.rb` (full rewrite of `reason_for`)
- Modify: `web/app/services/assistant/activation.rb:8` (drop `directory:`)
- Test: `web/test/services/assistant/provider_credentials_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Assistant::ProviderCredentials.statuses` → `[Status(slug:, reason:, available:)]` with **no keyword arguments**; `available_slugs` likewise. `Assistant::ProviderCatalog::Entry#secret_env` → `String`. `Assistant::Activation.state` → `State(active:, available_slugs:, reason:)`, no keyword arguments.

- [ ] **Step 1: Write the failing test**

Replace the directory-based cases in `web/test/services/assistant/provider_credentials_test.rb` with env cases:

```ruby
require "test_helper"

class Assistant::ProviderCredentialsTest < ActiveSupport::TestCase
  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "absent when the variable is unset" do
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => nil) do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "absent", status.reason
      refute status.available
    end
  end

  test "empty when the variable is whitespace" do
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "   \n") do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "empty", status.reason
    end
  end

  test "placeholder when the shipped example value is left in place" do
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "replace_with_your_key") do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "placeholder", status.reason
    end
  end

  test "oversize when the value exceeds MAX_BYTES" do
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "k" * (Assistant::ProviderCredentials::MAX_BYTES + 1)) do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "oversize", status.reason
    end
  end

  test "valid for a plausible key and only that provider becomes available" do
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "sk-ant-real", "ASSISTANT_OPENAI_API_KEY" => nil) do
      assert_equal [ "anthropic_primary" ], Assistant::ProviderCredentials.available_slugs
    end
  end

  test "statuses takes no keyword arguments" do
    assert_equal 0, Assistant::ProviderCredentials.method(:statuses).arity
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web && bin/rails test test/services/assistant/provider_credentials_test.rb`
Expected: FAIL — `statuses` still requires `directory:`, and `secret_env` is undefined.

- [ ] **Step 3: Rename the catalog key**

In `web/config/assistant_provider_catalog.yml`, replace both `secret_file:` lines:

```yaml
openai_primary:
  provider: openai
  model: gpt-5
  secret_ref: openai_primary
  secret_env: ASSISTANT_OPENAI_API_KEY
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard

anthropic_primary:
  provider: anthropic
  model: claude-sonnet-5
  secret_ref: anthropic_primary
  secret_env: ASSISTANT_ANTHROPIC_API_KEY
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard
```

Then in `web/app/services/assistant/provider_catalog.rb` rename the `secret_file` attribute and its YAML fetch to `secret_env`. Grep first: `grep -rn "secret_file" web/ assistant/` and update every hit in Ruby (Go is Task 2).

- [ ] **Step 4: Rewrite `reason_for` against ENV**

Replace the body of `web/app/services/assistant/provider_credentials.rb` with:

```ruby
module Assistant
  # Classifies each provider key environment variable into one stable reason
  # code. A value's contents never leave this module: only a reason code is
  # returned.
  module ProviderCredentials
    Status = Data.define(:slug, :reason, :available)

    # Mirrors the gateway's maxSecretBytes (16 << 10) so a value this preflight
    # calls oversize is exactly a value the gateway would refuse to load.
    MAX_BYTES = 16 * 1024
    PLACEHOLDER = /\Areplace_with_/i

    module_function

    def statuses
      ProviderCatalog.entries.values.map { |entry| status(entry) }
    end

    def available_slugs
      statuses.select(&:available).map(&:slug)
    end

    def status(entry)
      reason = reason_for(entry)
      Status.new(slug: entry.slug, reason: reason, available: reason == "valid")
    end

    # Reason codes are deliberately fewer than the file-based predecessor:
    # symlink, bad_mode and unreadable were properties of a file on a mount and
    # have no environment-variable equivalent.
    def reason_for(entry)
      raw = ENV[entry.secret_env]
      return "absent" if raw.nil?
      return "oversize" if raw.bytesize > MAX_BYTES

      body = raw.strip
      return "empty" if body.empty?
      return "placeholder" if body.match?(PLACEHOLDER)

      "valid"
    end
    private_class_method :reason_for
  end
end
```

- [ ] **Step 5: Drop `directory:` from Activation**

In `web/app/services/assistant/activation.rb`, change the signature and the call:

```ruby
def state
  return State.new(active: false, available_slugs: [], reason: "disabled_by_environment") if killed?

  reasons = Config.configuration_reasons
  return State.new(active: false, available_slugs: [], reason: reasons.first) if reasons.any?

  slugs = ProviderCredentials.available_slugs
  if slugs.empty?
    State.new(active: false, available_slugs: [], reason: "no_provider_credentials")
  else
    State.new(active: true, available_slugs: slugs, reason: "active")
  end
end
```

Then `grep -rn "Activation.state(\|available_slugs(\|statuses(\|DEFAULT_DIRECTORY" web/` and fix every caller — `Assistant::Config.enabled?`, the settings views, and the disabled-reason tests all pass `directory:` today.

- [ ] **Step 6: Run the full assistant Ruby suite**

Run: `cd web && bin/rails test test/services/assistant test/models/assistant test/integration/api/v1/assistant`
Expected: PASS. Reason-code assertions naming `bad_mode`, `symlink`, or `unreadable` must be deleted, not adapted — those states no longer exist.

- [ ] **Step 7: Commit**

```bash
git add web/config/assistant_provider_catalog.yml web/app/services/assistant web/test
git commit -m "Derive Assistant provider availability from environment variables instead of key files."
```

---

### Task 2: Gateway configuration from environment

**Files:**
- Modify: `assistant/gateway/internal/config/config.go`
- Test: `assistant/gateway/internal/config/config_test.go`

**Interfaces:**
- Consumes: the `secret_env` names from Task 1.
- Produces: `config.Load() (Config, error)` reading env only. `Config{GatewayMCPToken, IngressToken string; ProviderSecrets *SecretResolver; AvailableProfiles []string}` — `AMQPPassword` and the `AMQPURL()` method are **removed**. `SecretResolver.Resolve(reference string) (string, error)` keeps its signature.

- [ ] **Step 1: Write the failing test**

```go
func TestLoadReadsProviderKeysFromEnvironment(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", strings.Repeat("m", 32))
	t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", strings.Repeat("i", 32))
	t.Setenv("ASSISTANT_ANTHROPIC_API_KEY", "sk-ant-real")
	t.Setenv("ASSISTANT_OPENAI_API_KEY", "")

	settings, err := config.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := settings.AvailableProfiles; len(got) != 1 || got[0] != "anthropic_primary" {
		t.Fatalf("AvailableProfiles = %v, want [anthropic_primary]", got)
	}
	key, err := settings.ProviderSecrets.Resolve("anthropic_primary")
	if err != nil || key != "sk-ant-real" {
		t.Fatalf("Resolve = %q, %v", key, err)
	}
}

func TestLoadRejectsMissingIngressToken(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", strings.Repeat("m", 32))
	t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", "")
	if _, err := config.Load(); err == nil {
		t.Fatal("Load: want error for missing ingress token")
	}
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd assistant/gateway && go test ./internal/config/ -run TestLoad -v`
Expected: FAIL to compile — `Load` takes a directory today and `IngressToken` does not exist.

- [ ] **Step 3: Replace the file machinery with env reads**

In `config.go`: delete `defaultProviderSecretDir`, `machineSecretDir`, `defaultSecretFiles`, `LoadFrom`, and the `safeSecretMode` probe. Replace with:

```go
var providerSecretEnv = map[string]string{
	"openai_primary":    "ASSISTANT_OPENAI_API_KEY",
	"anthropic_primary": "ASSISTANT_ANTHROPIC_API_KEY",
}

type SecretResolver struct {
	values map[string]string
}

func (resolver *SecretResolver) Resolve(reference string) (string, error) {
	value, ok := resolver.values[reference]
	if !ok {
		return "", errors.New("unknown provider reference")
	}
	if !validCredential(value) {
		return "", errors.New("unusable provider credential")
	}
	return value, nil
}

func Load() (Config, error) {
	mcpToken := os.Getenv("ASSISTANT_GATEWAY_MCP_TOKEN")
	ingressToken := os.Getenv("ASSISTANT_GATEWAY_INGRESS_TOKEN")
	if !validCredential(mcpToken) || !validCredential(ingressToken) {
		return Config{}, errors.New("assistant gateway machine credential rejected")
	}

	values := make(map[string]string, len(providerSecretEnv))
	available := make([]string, 0, len(providerSecretEnv))
	for reference, name := range providerSecretEnv {
		value := os.Getenv(name)
		values[reference] = value
		if ProviderStatus(value) == "valid" {
			available = append(available, reference)
		}
	}
	sort.Strings(available)

	return Config{
		GatewayMCPToken:   mcpToken,
		IngressToken:      ingressToken,
		ProviderSecrets:   &SecretResolver{values: values},
		AvailableProfiles: available,
	}, nil
}
```

Keep the existing `validCredential` (it already rejects NUL/CR/LF/tab/space). Rewrite the preflight classifier as `ProviderStatus(value string) string` returning `absent`/`empty`/`placeholder`/`oversize`/`valid`, mirroring Task 1's reason codes exactly — the contract test in Task 9 asserts the two vocabularies match.

`sort.Strings` is required: map iteration order is random, and `AvailableProfiles` is logged and asserted on.

- [ ] **Step 4: Run the config tests**

Run: `cd assistant/gateway && go test ./internal/config/ -v`
Expected: PASS. Delete any test that redirects `machineSecretDir` or writes temp key files.

- [ ] **Step 5: Commit**

```bash
git add assistant/gateway/internal/config
git commit -m "Read Assistant gateway provider keys and machine tokens from the environment."
```

---

### Task 3: Gateway `POST /turns` route

**Files:**
- Rename: `assistant/gateway/internal/queue/consumer.go` → `assistant/gateway/internal/turn/turn.go` (package `turn`)
- Create: `assistant/gateway/internal/turn/http.go`
- Modify: `assistant/gateway/cmd/hunter-assistant-gateway/main.go`
- Test: `assistant/gateway/internal/turn/http_test.go`

**Interfaces:**
- Consumes: `config.Config.IngressToken` (Task 2); the surviving `turn.DecodeTurnJob(payload []byte, now time.Time) (TurnJob, error)` and `(*turn.Processor).Process(ctx context.Context, job TurnJob) []AssistantEvent`.
- Produces: `turn.NewTurnHandler(opts turn.HandlerOptions) http.Handler`, where

```go
type HandlerOptions struct {
	Processor      *Processor
	IngressToken   string
	AllowedHosts   []string
	AllowedOrigins []string
	MaxConcurrent  int
	Ready          *atomic.Bool
	Now            func() time.Time
}
```

Response body is `{"schema_version":1,"correlation_id":"…","events":[…]}`; errors are `{"error":{"code":"…"}}`.

- [ ] **Step 1: Rename the package, keeping every pure function**

```bash
cd assistant/gateway
git mv internal/queue internal/turn
git mv internal/turn/consumer.go internal/turn/turn.go
git mv internal/turn/consumer_test.go internal/turn/turn_test.go
```

Change `package queue` → `package turn` in both files. Delete `Run` (192-244) and `publishEvent` (245-269), the `eventExchange`/`eventRoutingKey` constants, and the `amqp` import. Keep `DecodeTurnJob`, `Process`, `newEvent`, `errorEvent`, `newUUID`, `decodeClosed`, `unsafeText`, `ConnectMCP` and all types unchanged.

In `Process` (126), delete the `progress` seed event — change

```go
events := []AssistantEvent{newEvent(job, "progress", map[string]any{"status": "running"})}
```

to

```go
events := make([]AssistantEvent, 0, 2)
```

Then `go build ./...` and fix the `queue.` references in `main.go` to `turn.`.

- [ ] **Step 2: Write the failing handler test**

```go
func TestTurnHandlerRejectsMissingBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "assistant-gateway:8081"
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", recorder.Code)
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

func TestTurnHandlerReturnsEventsWithoutProgressKind(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "assistant-gateway:8081"
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		SchemaVersion int `json:"schema_version"`
		Events        []struct{ Kind string } `json:"events"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.SchemaVersion != 1 {
		t.Fatalf("schema_version = %d, want 1", body.SchemaVersion)
	}
	for _, event := range body.Events {
		if event.Kind == "progress" {
			t.Fatal("progress events must no longer be emitted")
		}
	}
}

func TestTurnHandlerReturns503WhenNotReady(t *testing.T) {
	handler := newTestHandler(t, "secret-token")  // helper stores ready=false for this case
	// ... assert 503
}
```

Write `newTestHandler` and `validEnvelopeJSON` as helpers in the same file, building a `Processor` with a stub `Generator` and a stub `MCPConnect` that returns a no-op `ToolSession`. Model the stubs on the existing ones in `turn_test.go`.

- [ ] **Step 3: Run it and confirm it fails**

Run: `cd assistant/gateway && go test ./internal/turn/ -run TestTurnHandler -v`
Expected: FAIL to compile — `NewTurnHandler` does not exist.

- [ ] **Step 4: Implement the handler**

Create `internal/turn/http.go`:

```go
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

func NewTurnHandler(opts HandlerOptions) http.Handler {
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
```

`Process` already bounds itself by `ExpiresAt` capped at `maxTurnDuration`, so the handler adds no deadline of its own.

- [ ] **Step 5: Mount the route and delete the AMQP run loop**

In `cmd/hunter-assistant-gateway/main.go`: raise the server's timeouts (the health-only values are far too short for a turn), register both routes on one mux, and replace the `queue.Run` block.

```go
const listenAddress = "0.0.0.0:8081"

// ... after building `processor` and before ready.Store(true):
mux := http.NewServeMux()
mux.Handle("/healthz", newHealthHandler(&ready))
mux.Handle("/turns", turn.NewTurnHandler(turn.HandlerOptions{
	Processor:      processor,
	IngressToken:   settings.IngressToken,
	AllowedHosts:   splitList(os.Getenv("ASSISTANT_GATEWAY_ALLOWED_HOSTS")),
	AllowedOrigins: splitList(os.Getenv("ASSISTANT_GATEWAY_ALLOWED_ORIGINS")),
	MaxConcurrent:  intFromEnv("ASSISTANT_MAX_CONCURRENT_TURNS", 2),
	Ready:          &ready,
}))
```

The single `http.Server` needs `ReadTimeout`/`WriteTimeout` of at least the grant TTL plus a margin (use `310 * time.Second`); keep `ReadHeaderTimeout: 2 * time.Second` and `MaxHeaderBytes: 4 << 10`. Then delete the `queue.Run` call, `settings.AMQPURL()`, and block on `ctx.Done()` instead — `serveHealthOnly` already does exactly that, so the ready path can call it too.

Add small `splitList` and `intFromEnv` helpers in `main.go`.

- [ ] **Step 6: Run the gateway suite**

Run: `cd assistant/gateway && go build ./... && go test ./... -v`
Expected: PASS. `turn_test.go` cases covering `Run`/`publishEvent` are deleted; any asserting a `progress` event is updated.

- [ ] **Step 7: Commit**

```bash
git add assistant/gateway
git commit -m "Serve Assistant turns over an authenticated HTTP route instead of an AMQP consumer."
```

---

### Task 4: Validator `POST /validations` route

**Files:**
- Modify: `assistant/validator/internal/worker/worker.go`
- Create: `assistant/validator/internal/worker/http.go`
- Modify: `assistant/validator/cmd/*/main.go`
- Test: `assistant/validator/internal/worker/http_test.go`

**Interfaces:**
- Consumes: surviving `worker.DecodeJob(payload []byte, now time.Time) (Job, error)` and `(worker.Processor).Process(ctx context.Context, job Job) Event`.
- Produces: `worker.NewValidationHandler(opts worker.HandlerOptions) http.Handler` with the same `HandlerOptions` field names as Task 3 except `Processor Processor` (value, not pointer — `Process` has a value receiver at `worker.go:76`). Response: `{"schema_version":1,"event":{…}}`.

- [ ] **Step 1: Delete the AMQP functions**

Remove `Run` (104-153) and `publishEvent` (154-181), the `validationExchange`/`validationRoutingKey` constants, and the `amqp` import from `worker.go`. Keep `DecodeJob`, `Process`, `validResult`, `decodeClosed`, `newUUID`.

- [ ] **Step 2: Write the failing test**

```go
func TestValidationHandlerRejectsMissingBearer(t *testing.T) {
	handler := newTestHandler(t, "validator-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
	request.Host = "assistant-validator:8082"
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", recorder.Code)
	}
}

func TestValidationHandlerReturnsOneEvent(t *testing.T) {
	handler := newTestHandler(t, "validator-token")
	request := httptest.NewRequest(http.MethodPost, "/validations", strings.NewReader(validJobJSON(t)))
	request.Host = "assistant-validator:8082"
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
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `cd assistant/validator && go test ./internal/worker/ -run TestValidationHandler -v`
Expected: FAIL to compile — `NewValidationHandler` undefined.

- [ ] **Step 4: Implement the handler**

Copy `internal/turn/http.go` from Task 3 into `internal/worker/http.go`, changing: `package worker`; `Processor Processor` (value receiver); the response struct to `{SchemaVersion int; Event Event}`; `DecodeTurnJob` → `DecodeJob`; and `Process` returning a single `Event` rather than a slice. Keep the same status codes and error-code strings so the two services behave identically.

**This duplication is deliberate and must be guarded.** The three Go services
are independent modules with narrow Docker build contexts, so sharing the code
would mean raising both contexts and adding `replace` directives — a worse trade
than duplication (module consolidation is a separate follow-up plan). To stop the
two copies diverging, the shared behaviour is pinned by one case table read by
both modules.

Create `assistant/contracts/v1/http_ingress_cases.json`:

```json
{
  "cases": [
    { "name": "missing_bearer",   "authorization": "",                    "host": "VALID_HOST", "origin": "",           "want_status": 401, "want_code": "unauthorized" },
    { "name": "wrong_bearer",     "authorization": "Bearer wrong-token",  "host": "VALID_HOST", "origin": "",           "want_status": 401, "want_code": "unauthorized" },
    { "name": "unknown_host",     "authorization": "Bearer VALID_TOKEN",  "host": "evil.example.com", "origin": "",     "want_status": 403, "want_code": "host_not_allowed" },
    { "name": "unknown_origin",   "authorization": "Bearer VALID_TOKEN",  "host": "VALID_HOST", "origin": "http://evil", "want_status": 403, "want_code": "origin_not_allowed" },
    { "name": "accepted",         "authorization": "Bearer VALID_TOKEN",  "host": "VALID_HOST", "origin": "",           "want_status": 200, "want_code": "" }
  ]
}
```

Then add `TestIngressContractCases` to **both** `assistant/gateway/internal/turn/http_test.go` and `assistant/validator/internal/worker/http_test.go`. Each reads the same file via a relative path (`../../../contracts/v1/http_ingress_cases.json`), substitutes its own `VALID_HOST` and `VALID_TOKEN`, and asserts the status and `error.code` for every case:

```go
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
```

The gateway copy is identical except for `validHost`, the `/turns` path, and `validEnvelopeJSON`. Because both read one file, changing the shared contract in one service fails the other service's suite.

- [ ] **Step 5: Mount the route**

Mirror Task 3 Step 5 in the validator's `main.go`: one mux with `/healthz` and `/validations`, generous `ReadTimeout`/`WriteTimeout`, token from `ASSISTANT_VALIDATOR_INGRESS_TOKEN`, hosts/origins from `ASSISTANT_VALIDATOR_ALLOWED_HOSTS` / `ASSISTANT_VALIDATOR_ALLOWED_ORIGINS`, then block on `ctx.Done()` instead of calling `Run`.

- [ ] **Step 6: Run the validator suite**

Run: `cd assistant/validator && go build ./... && go test ./... -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add assistant/validator
git commit -m "Serve Assistant draft validation over an authenticated HTTP route instead of an AMQP worker."
```

---

### Task 5: Rails calls the gateway and the validator

**Files:**
- Create: `web/app/services/assistant/gateway_client.rb`
- Create: `web/app/services/assistant/validator_client.rb`
- Create: `web/app/jobs/assistant/turn_job.rb`
- Modify: `web/app/services/assistant/turn_dispatcher.rb:38-47`
- Modify: `web/app/services/assistant/validation_dispatcher.rb`
- Test: `web/test/services/assistant/gateway_client_test.rb`, `web/test/jobs/assistant/turn_job_test.rb`

**Interfaces:**
- Consumes: the `/turns` and `/validations` contracts from Tasks 3–4; the existing `Assistant::QueueContracts.validate_turn_job!` / `validate_assistant_event!`; the existing `Assistant::EventIngestor` ingest entry point (check its exact method name with `grep -n "def " web/app/services/assistant/event_ingestor.rb` before writing the job).
- Produces: `Assistant::GatewayClient.run_turn(envelope) → Array<Hash>` (raises `Assistant::GatewayClient::Error`); `Assistant::ValidatorClient.validate(envelope) → Hash`; `Assistant::TurnJob.perform_later(turn_id:, envelope:)`.

- [ ] **Step 1: Write the failing client test**

```ruby
require "test_helper"

class Assistant::GatewayClientTest < ActiveSupport::TestCase
  test "posts the envelope with the bearer token and returns the events" do
    envelope = { "schema_version" => 1, "correlation_id" => SecureRandom.uuid }
    captured = nil
    body = { "schema_version" => 1, "correlation_id" => envelope["correlation_id"],
             "events" => [ { "kind" => "assistant_message" } ] }

    stub_methods(Assistant::GatewayClient, post: ->(uri, json, token) {
      captured = { uri: uri, json: json, token: token }
      body
    }) do
      assert_equal [ { "kind" => "assistant_message" } ], Assistant::GatewayClient.run_turn(envelope)
    end
    assert_equal "/turns", URI(captured[:uri]).path
  end

  test "raises when the gateway returns an error envelope" do
    stub_methods(Assistant::GatewayClient, post: ->(*) { { "error" => { "code" => "gateway_saturated" } } }) do
      error = assert_raises(Assistant::GatewayClient::Error) { Assistant::GatewayClient.run_turn({}) }
      assert_equal "gateway_saturated", error.code
    end
  end
end
```

Use the `stub_methods` helper in `web/test/test_helper.rb` (Minitest 6 dropped bundled mocks). Read it first to match its exact calling convention.

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web && bin/rails test test/services/assistant/gateway_client_test.rb`
Expected: FAIL — `Assistant::GatewayClient` is not defined.

- [ ] **Step 3: Implement the two clients**

```ruby
require "net/http"

module Assistant
  # Runs one turn against the gateway and returns its ordered event array. The
  # gateway holds no Hunter identity, so this is the only direction of travel:
  # Rails calls out, the gateway answers on the same connection.
  module GatewayClient
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    module_function

    def run_turn(envelope)
      body = post(endpoint, JSON.generate(envelope), token)
      raise Error, body.dig("error", "code").presence || "gateway_error" if body.key?("error")
      raise Error, "invalid_response" unless body["schema_version"] == 1

      Array(body["events"])
    end

    def endpoint
      "#{ENV.fetch('ASSISTANT_GATEWAY_URL', 'http://assistant-gateway:8081')}/turns"
    end

    def token
      ENV.fetch("ASSISTANT_GATEWAY_INGRESS_TOKEN")
    end

    def post(uri, json, bearer)
      parsed = URI(uri)
      request = Net::HTTP::Post.new(parsed)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{bearer}"
      request.body = json
      timeout = Assistant::Config::HARD_LIMITS.fetch(:grant_ttl_seconds) + 10
      response = Net::HTTP.start(parsed.host, parsed.port,
        open_timeout: 5, read_timeout: timeout, write_timeout: 10) { |http| http.request(request) }
      JSON.parse(response.body.to_s.presence || "{}")
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError
      { "error" => { "code" => "gateway_unreachable" } }
    end
  end
end
```

Write `Assistant::ValidatorClient` the same way against `ASSISTANT_VALIDATOR_URL` (default `http://assistant-validator:8082`), `ASSISTANT_VALIDATOR_INGRESS_TOKEN`, path `/validations`, returning `body["event"]`.

- [ ] **Step 4: Write the job**

```ruby
module Assistant
  # One attempt only: the gateway is not idempotent with respect to provider
  # spend, so a retry would bill a second call and could double-write a draft.
  # A failure becomes an error event and the operator resends from the chat.
  class TurnJob < ApplicationJob
    queue_as :default
    retry_on Exception, attempts: 1

    def perform(turn_id:, envelope:)
      turn = Assistant::Turn.find_by(id: turn_id)
      return unless turn
      return unless turn.status == "queued"

      turn.update!(status: "running", started_at: Time.current)
      events = Assistant::GatewayClient.run_turn(envelope)
      ingest!(turn, events)
    rescue Assistant::GatewayClient::Error => error
      ingest!(turn, [ error_event(turn, envelope, error.code) ])
    end

    private

    def ingest!(turn, events)
      ActiveRecord::Base.transaction do
        events.each do |event|
          Assistant::QueueContracts.validate_assistant_event!(event)
          Assistant::EventIngestor.ingest!(event)
        end
      end
    end

    def error_event(turn, envelope, code)
      {
        "schema_version" => 1, "event_id" => SecureRandom.uuid,
        "correlation_id" => envelope.fetch("correlation_id"), "turn_id" => turn.id,
        "provider_profile_id" => turn.provider_profile_id,
        "kind" => "error", "data" => { "code" => code.to_s.first(100) }
      }
    end
  end
end
```

Confirm `Assistant::EventIngestor`'s real method name and arity first, and confirm the `Turn` column names (`started_at` may not exist — check `db/schema.rb`). Adjust rather than inventing columns.

- [ ] **Step 5: Retarget the dispatchers**

In `turn_dispatcher.rb`, replace the `Assistant::Broker.publish(...)` call (lines 38-47) with:

```ruby
turn.update!(status: "queued", queued_at: Time.current)
Assistant::TurnJob.perform_later(turn_id: turn.id, envelope: body)
```

In `validation_dispatcher.rb`, replace its `Broker.publish` with a `ValidatorClient.validate` call feeding the existing `ingest!`.

- [ ] **Step 6: Run the suite**

Run: `cd web && bin/rails test test/services/assistant test/jobs test/integration/api/v1/assistant`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add web/app web/test
git commit -m "Dispatch Assistant turns and validations over HTTP from a Solid Queue job."
```

---

### Task 6: Delete the broker, the consumer and the one-shots

**Files:**
- Delete: `web/app/services/assistant/broker.rb`, `web/app/services/assistant/event_consumer.rb`, `web/app/services/assistant/bootstrap_service_token.rb`
- Delete: `ops/assistant/provision_rabbitmq.rb`, `ops/assistant/bootstrap.sh`, `ops/assistant/bootstrap_service_token.rb`, `ops/assistant/rabbitmq/`, `assistant/egress/`
- Modify: `web/db/seeds.rb`
- Delete: `web/test/config/assistant_rabbitmq_entrypoint_test.rb`, `web/test/config/assistant_bootstrap_test.rb`
- Test: `web/test/models/assistant/service_identity_test.rb` (add the seed case)

**Interfaces:**
- Consumes: `ASSISTANT_MCP_HUNTER_TOKEN`; the existing `Assistant::ServiceIdentity.digest(raw)`.
- Produces: a seeded `Assistant::ServiceIdentity` with `name: "hunter-mcp"`, `role: "mcp_reader"`, `enabled: true`.

- [ ] **Step 1: Write the failing seed test**

```ruby
test "seeding installs the hunter-mcp identity from the environment and rotates any predecessor" do
  previous = Assistant::ServiceIdentity.create!(
    name: "hunter-mcp-old", role: "mcp_reader", token_digest: Assistant::ServiceIdentity.digest("old")
  )
  raw = "mcp-token-#{SecureRandom.hex(8)}"

  Assistant::ServiceIdentity.install_from_environment!(raw)

  assert_not previous.reload.enabled
  identity = Assistant::ServiceIdentity.find_by(name: "hunter-mcp", enabled: true)
  assert_equal Assistant::ServiceIdentity.digest(raw), identity.token_digest
end

test "installing is idempotent for an unchanged token" do
  raw = "mcp-token-stable"
  Assistant::ServiceIdentity.install_from_environment!(raw)
  assert_no_difference -> { Assistant::ServiceIdentity.where(enabled: true).count } do
    Assistant::ServiceIdentity.install_from_environment!(raw)
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web && bin/rails test test/models/assistant/service_identity_test.rb`
Expected: FAIL — `install_from_environment!` undefined.

- [ ] **Step 3: Implement it on the model and call it from the seed**

Add to `web/app/models/assistant/service_identity.rb`, inside `class << self`:

```ruby
# Replaces BootstrapServiceToken: the operator supplies the raw value and
# Postgres keeps only its digest, so no raw token transits a shared volume.
def install_from_environment!(raw)
  digest = digest(raw)
  transaction do
    return find_by!(token_digest: digest) if exists?(token_digest: digest, enabled: true, role: "mcp_reader")

    where(enabled: true, role: "mcp_reader").find_each do |existing|
      existing.update!(enabled: false, rotated_at: Time.current)
    end
    create!(name: "hunter-mcp", role: "mcp_reader", token_digest: digest)
  end
end
```

Append to `web/db/seeds.rb`:

```ruby
raw_mcp_token = ENV["ASSISTANT_MCP_HUNTER_TOKEN"].to_s
if raw_mcp_token.strip.empty?
  Rails.logger.info("[assistant] ASSISTANT_MCP_HUNTER_TOKEN unset; hunter-mcp identity not installed")
else
  Assistant::ServiceIdentity.install_from_environment!(raw_mcp_token)
end
```

- [ ] **Step 4: Delete the dead files**

```bash
cd /home/claude/workspace
git rm web/app/services/assistant/broker.rb \
       web/app/services/assistant/event_consumer.rb \
       web/app/services/assistant/bootstrap_service_token.rb \
       ops/assistant/provision_rabbitmq.rb \
       ops/assistant/bootstrap.sh \
       ops/assistant/bootstrap_service_token.rb \
       web/test/config/assistant_rabbitmq_entrypoint_test.rb \
       web/test/config/assistant_bootstrap_test.rb
git rm -r ops/assistant/rabbitmq assistant/egress
```

Then remove `bunny` from `web/Gemfile` and run `bundle install`. Grep for stragglers: `grep -rn "Broker\|EventConsumer\|BootstrapServiceToken\|bunny\|AMQP\|amqp" web/app web/config web/test web/Gemfile Procfile.dev` and clear every hit, including the `worker`/consumer entry in `Procfile.dev` if one exists for the event consumer.

- [ ] **Step 5: Run the whole Ruby suite**

Run: `cd web && bin/rails test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Delete the Assistant AMQP broker, event consumer and bootstrap one-shots in favour of an environment-seeded service identity."
```

---

### Task 7: Compose surgery

**Files:**
- Modify: `docker-compose.yaml`, `docker-compose.prod.yaml`, `.env.example`, `Dockerfile`, `.dockerignore`
- Test: `web/test/config/assistant_compose_test.rb`, `web/test/contracts/assistant_secret_paths_test.rb`

**Interfaces:**
- Consumes: every env name introduced in Tasks 1–5.
- Produces: an 8-service dev stack; 4 internal networks named `assistant-rails-gateway`, `assistant-gateway-mcp`, `assistant-mcp-rails`, `assistant-rails-validator`.

- [ ] **Step 1: Write the failing compose contract tests**

Add to `web/test/contracts/assistant_secret_paths_test.rb`:

```ruby
REMOVED_SERVICES = %w[
  rabbitmq assistant-egress assistant-events
  assistant-secrets-init assistant-token-init assistant-rabbitmq-init
].freeze
PROVIDER_KEY_ENV = %w[ASSISTANT_ANTHROPIC_API_KEY ASSISTANT_OPENAI_API_KEY].freeze
SECRET_FREE_SERVICES = %w[runner ansible-executor].freeze

def test_the_retired_services_and_volume_are_gone
  %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
    config = YAML.safe_load_file(ROOT.join(name), aliases: true)
    REMOVED_SERVICES.each do |service|
      refute config.fetch("services").key?(service), "#{name} still defines #{service}"
    end
    refute (config["volumes"] || {}).key?("assistant_secrets"), "#{name} still defines assistant_secrets"
    config.fetch("services").each do |service_name, service|
      Array(service["volumes"]).each do |mount|
        refute_includes mount.to_s, "/run/secrets", "#{name}: #{service_name} still mounts /run/secrets"
        refute_includes mount.to_s, "/run/assistant/secrets", "#{name}: #{service_name} still mounts the retired volume"
      end
    end
  end
end

def test_provider_keys_never_reach_the_execution_services
  %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
    config = YAML.safe_load_file(ROOT.join(name), aliases: true)
    SECRET_FREE_SERVICES.each do |service_name|
      service = config.fetch("services")[service_name]
      next unless service

      environment = service.fetch("environment", {})
      keys = environment.is_a?(Hash) ? environment.keys : environment.map { |e| e.split("=").first }
      PROVIDER_KEY_ENV.each do |secret|
        refute_includes keys, secret, "#{name}: #{service_name} receives #{secret}"
      end
    end
  end
end
```

- [ ] **Step 2: Run and confirm they fail**

Run: `cd web && bundle exec ruby test/contracts/assistant_secret_paths_test.rb`
Expected: FAIL — the six services still exist.

- [ ] **Step 3: Edit both compose files**

Delete the six service blocks. Then:

- `web`: drop the `assistant_secrets` and `./secrets` mounts, the `rabbitmq` dependency, and every `ASSISTANT_AMQP_*`/`RABBITMQ_*` variable. Add `ASSISTANT_ANTHROPIC_API_KEY`, `ASSISTANT_OPENAI_API_KEY`, `ASSISTANT_MCP_HUNTER_TOKEN`, `ASSISTANT_GATEWAY_INGRESS_TOKEN`, `ASSISTANT_VALIDATOR_INGRESS_TOKEN`, `ASSISTANT_GATEWAY_URL`, `ASSISTANT_VALIDATOR_URL` under `environment:` with `${VAR}` substitution. Networks: `default`, `assistant-rails-gateway`, `assistant-rails-validator`, `assistant-mcp-rails`.
- `assistant-gateway`: `ASSISTANT_GATEWAY_MCP_TOKEN`, `ASSISTANT_GATEWAY_INGRESS_TOKEN`, both provider keys, `ASSISTANT_GATEWAY_ALLOWED_HOSTS: assistant-gateway:8081`, `ASSISTANT_GATEWAY_ALLOWED_ORIGINS: http://web:5000`, `ASSISTANT_MAX_CONCURRENT_TURNS`. Networks: `assistant-rails-gateway`, `assistant-gateway-mcp`, and a non-internal network for provider egress. Drop all AMQP env and the secrets mounts.
- `hunter-mcp`: `ASSISTANT_GATEWAY_MCP_TOKEN`, `ASSISTANT_MCP_HUNTER_TOKEN`. `depends_on` reduces to `web: service_started`.
- `assistant-validator`: `ASSISTANT_VALIDATOR_INGRESS_TOKEN`, `ASSISTANT_VALIDATOR_ALLOWED_HOSTS`, `ASSISTANT_VALIDATOR_ALLOWED_ORIGINS`. Networks: `assistant-rails-validator` only.
- Networks block: delete `assistant-queue`, `assistant-gateway-queue`, `assistant-validator-queue`, `assistant-egress-in`, `assistant-egress-out`; add `assistant-rails-gateway` and `assistant-rails-validator` as `internal: true`.
- Volumes block: delete `assistant_secrets` **and the upgrade-hazard comment at lines 603-613**, which no longer describes anything.
- Keep every hardening key already present on the surviving services (`user`, `read_only`, `cap_drop`, `security_opt`, `tmpfs`, `mem_limit`, `pids_limit`).

Update `.env.example` with all six secrets, each documented and set to `replace_with_...` so the placeholder reason code is exercised. Do **not** put real values in `.env.example`.

- [ ] **Step 4: Reconcile `assistant_compose_test.rb`**

Update `ASSISTANT_SERVICES`, `UNTRUSTED_SERVICES`, `ALLOWED_HOST_MOUNTS` (now empty for every service), `NETWORKS`, and delete `ASSISTANT_SECRETS_VOLUME_RO` and the provider-mount tests. Keep every hardening assertion.

- [ ] **Step 5: Run both suites plus a compose parse**

Run:
```bash
cd web && bundle exec ruby test/contracts/assistant_secret_paths_test.rb && bundle exec ruby test/config/assistant_compose_test.rb
cd .. && docker compose config >/dev/null && docker compose -f docker-compose.prod.yaml config >/dev/null
```
Expected: PASS, and both compose files parse.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Reduce the Assistant Compose topology to eight services with environment-supplied secrets."
```

---

### Task 8: End-to-end verification

**Files:** none — this task changes nothing and produces evidence.

- [ ] **Step 1: Boot the stack from clean**

```bash
cd /home/claude/workspace
docker compose down -v
docker compose build
docker compose up -d
docker compose ps
```
Expected: eight services, all healthy. No container restarting.

- [ ] **Step 2: Confirm every deleted failure mode is actually gone**

```bash
docker compose logs 2>&1 | grep -Ei "master.key|EACCES|traces|amqp|rabbit|squid" || echo "clean"
docker volume ls | grep assistant_secrets || echo "volume absent"
```
Expected: `clean` and `volume absent`.

- [ ] **Step 3: Drive one real turn through the browser**

Invoke the `verify` skill, or manually: log in as `ADMIN_USERNAME`, open the chat, send a prompt, and confirm an assistant message renders. Then check the audit trail is metadata-only:

```bash
docker compose exec web bin/rails runner 'pp Assistant::AuditEvent.order(:id).last(5).map { |e| [e.event, e.status] }'
```
Expected: a completed turn; no message bodies in audit rows.

- [ ] **Step 4: Confirm the negative paths**

```bash
# unauthenticated /turns must be rejected
docker compose exec web sh -c 'curl -s -o /dev/null -w "%{http_code}\n" -XPOST http://assistant-gateway:8081/turns -d "{}"'
```
Expected: `401`.

- [ ] **Step 5: Full test suites**

```bash
cd web && bin/rails test
cd ../assistant/gateway && go test ./...
cd ../validator && go test ./...
```
Expected: all PASS.

- [ ] **Step 6: Commit any fixes**

Only if steps 1-5 surfaced defects. One commit per root cause, following superpowers:systematic-debugging rather than patching symptoms.

---

### Task 9: Documentation and the threat-model delta

**Files:**
- Modify: `docs/security/hunter-assistant-threat-model.md`
- Modify: `docs/security/hunter-assistant-production-checklist.md`
- Modify: `docs/runbooks/hunter-assistant-incident-response.md`
- Modify: `AGENTS.md` (data-store / conventions section, if it names RabbitMQ)
- Create: `docs/superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md`

**Interfaces:** none — documentation only. Required by the Assistant capability rule in `AGENTS.md` before production is enabled.

- [ ] **Step 1: Rewrite the threat model's data flow**

`hunter-assistant-threat-model.md:44-62` describes a RabbitMQ turn and an allowlisted egress hop. Replace with the HTTP flow from the spec's §3. Update `:94-95` — "RabbitMQ messages are non-durable and tracing is disabled for the assistant vhost" now describes nothing; replace with the bearer-token-plus-internal-network statement. Keep every retained property (`:64-66`) verbatim.

- [ ] **Step 2: Write the delta document**

Create `docs/superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md` recording, for each of the five accepted consequences in the spec's §6: what the control was, what replaced it, why the residual risk is accepted, and what would reverse the decision. Mirror the structure of `2026-07-26-hunter-assistant-zero-step-activation-delta.md`.

- [ ] **Step 3: Update the checklist**

`hunter-assistant-production-checklist.md:86` reads "RabbitMQ tracing is disabled and the temporary provisioner user is absent" — both nouns are gone. Replace with items that are actually checkable now: the four tokens are set and distinct; no service mounts `./secrets`; `/turns` and `/validations` reject unauthenticated requests; `runner` and `ansible-executor` do not receive provider keys.

- [ ] **Step 4: Update the incident-response runbook**

`hunter-assistant-incident-response.md:37-39` tells the responder to preserve "RabbitMQ configuration metadata". Replace with the gateway/validator HTTP logs and the Solid Queue job records. Keep the "do not enable body tracing" instruction — still correct, now about application logging rather than a broker feature.

- [ ] **Step 5: Amend the zero-step activation delta**

Add a dated amendment to `2026-07-26-hunter-assistant-zero-step-activation-delta.md`: activation is still derived, but from environment variables, and the `symlink`/`bad_mode`/`unreadable` reason codes it documents no longer exist.

- [ ] **Step 6: Commit**

```bash
git add docs AGENTS.md
git commit -m "Record the Assistant infrastructure simplification threat-model delta and refresh the operator documents."
```

---

## Self-Review

**Spec coverage.** §3 architecture → Tasks 3-5, 7. §4.1/§4.2 contracts → Tasks 3, 4, 5. §4.3 `progress` removal → Task 3 Step 1 and Task 5. §4.4 single attempt → Task 5 Step 4 (`retry_on Exception, attempts: 1`). §5 secret model → Tasks 1, 2, 7; per-service scoping asserted in Task 7 Step 1. §5.1 activation → Task 1. §6 accepted consequences → Task 9 Step 2. §7 reliability → Task 8 Step 2. §8 deletion inventory → Tasks 6, 7. §9 testing → distributed across every task plus Task 8. §10 migration → Task 8 Step 1 and Task 7 Step 3 (`.env.example`).

**Placeholder scan.** No TBDs. Three steps deliberately instruct verification before writing rather than showing final code — Task 5's `EventIngestor` method name and `Turn` column names, and Task 1 Step 3's `secret_file` grep. These are directions to read existing code whose exact shape I have not opened, which is honest; inventing a signature there would be the actual failure.

**Type consistency.** `HandlerOptions` field names are identical in Tasks 3 and 4 except `Processor` pointer-vs-value, which is called out explicitly and follows the existing receivers (`*Processor` at `consumer.go:126`, value at `worker.go:76`). `ProviderStatus` (Task 2) returns the same five reason codes `reason_for` returns (Task 1), and Task 9 does not add a sixth. `install_from_environment!` is defined in Task 6 Step 3 and used only in Task 6 Step 3. `run_turn`/`validate` are defined and used in Task 5.

**Known gap, stated rather than hidden.** The spec's §4.1 caps the response at `MAX_EVENT_BYTES` (300,000) but no task asserts it — the gateway's `maxRequestBytes` bounds the *request*. If you want the response bound enforced, add an assertion in Task 5 Step 3 before `Array(body["events"])`.
