package runner

import (
	"context"
	"errors"
	"testing"
	"time"

	cc_run_groups "hunter.local/assistant/mcp/internal/modules/cc_run_groups"
	cc_runs "hunter.local/assistant/mcp/internal/modules/cc_runs"
	cc_templates "hunter.local/assistant/mcp/internal/modules/cc_templates"
	"hunter.local/assistant/mcp/internal/modules/ccwrite"
	cves "hunter.local/assistant/mcp/internal/modules/cves"
	sitemap "hunter.local/assistant/mcp/internal/modules/sitemap"
	targets "hunter.local/assistant/mcp/internal/modules/targets"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/transport"
)

func newTargetsRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(targets.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func newCvesRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(cves.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func newEndpointsRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(sitemap.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func newTemplatesRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(cc_templates.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func newCCWriteRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(ccwrite.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func TestCreateTemplateAllowedOnlyByDedicatedWriteScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","receipt":{"receipt_id":"3b241101-e2bb-4255-8caf-4136c566a963","tool":"create_whiterabbit_template","status":"created","target":{"type":"whiterabbit_template","id":"1"},"human_user_id":1,"turn_id":1,"idempotency_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","replayed":false,"occurred_at":"2026-08-19T00:00:00Z"}}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"create_whiterabbit_template"}, WriteScopes: []string{"control_center_templates_write"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newCCWriteRunner(b).Dispatch(context.Background(), "g", "create_whiterabbit_template", []byte(`{"template":{"name":"httpx proof","kind":"cmdscript","commands":[{"command":"httpx","args":["-l","targets.txt"]}]}}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("write scope happy path failed: %q %v", out, err)
	}
}

func TestCreateTemplateRejectsMissingOrMisclassifiedWriteScope(t *testing.T) {
	for _, grant := range []transport.Grant{
		{Tools: []string{"create_whiterabbit_template"}},
		{Tools: []string{"create_whiterabbit_template"}, ReadScopes: []string{"control_center_templates_write"}},
	} {
		grant.ExpiresAt = time.Now().Add(time.Minute)
		grant.CallsRemaining = 8
		grant.BytesRemaining = 4096
		_, err := newCCWriteRunner(fakeBackend{grant: grant}).Dispatch(context.Background(), "g", "create_whiterabbit_template", []byte(`{"template":{"name":"n","kind":"cmdscript","commands":[{"command":"httpx"}]}}`))
		if !errors.Is(err, ErrScopeDenied) {
			t.Fatalf("want ErrScopeDenied for grant %#v, got %v", grant, err)
		}
	}
}

// newAnsibleRunner registers both Control Center Ansible modules that share
// the control_center_ansible scope: run groups (list_run_groups, get_run_group)
// and runs (get_run — there is no list_runs; runs are reached via their parent
// run group).
func newAnsibleRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(cc_run_groups.Module{})
	reg.Add(cc_runs.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func TestListTargetsDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_targets"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newTargetsRunner(b).Dispatch(context.Background(), "g", "list_targets", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestListTargetsAllowedWithScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_targets"}, ReadScopes: []string{"targets"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newTargetsRunner(b).Dispatch(context.Background(), "g", "list_targets", []byte(`{"q":"example.com"}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

func TestGetTargetDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"get_target"}, ReadScopes: []string{"cves"}, // wrong scope
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newTargetsRunner(b).Dispatch(context.Background(), "g", "get_target", []byte(`{"id":"t1"}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

// --- Phase 2c: cves (Mongo module) ---------------------------------------

func TestListCvesDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_cves"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newCvesRunner(b).Dispatch(context.Background(), "g", "list_cves", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestListCvesAllowedWithScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_cves"}, ReadScopes: []string{"cves"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newCvesRunner(b).Dispatch(context.Background(), "g", "list_cves", []byte(`{"ecosystem":"PyPI"}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

// --- Phase 2c: sitemap endpoints (AR/Postgres module) ---------------------

func TestListEndpointsDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_endpoints"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newEndpointsRunner(b).Dispatch(context.Background(), "g", "list_endpoints", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestListEndpointsAllowedWithScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_endpoints"}, ReadScopes: []string{"sitemap"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newEndpointsRunner(b).Dispatch(context.Background(), "g", "list_endpoints", []byte(`{"path":"/api"}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

// --- Phase 2c: Control Center templates -----------------------------------

func TestListTemplatesDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_templates"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newTemplatesRunner(b).Dispatch(context.Background(), "g", "list_templates", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestListTemplatesAllowedWithScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_templates"}, ReadScopes: []string{"control_center_templates"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newTemplatesRunner(b).Dispatch(context.Background(), "g", "list_templates", []byte(`{"kind":"recon"}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

// --- Phase 2c: Control Center Ansible (list_run_groups / get_run) ---------

func TestListRunGroupsDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_run_groups"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newAnsibleRunner(b).Dispatch(context.Background(), "g", "list_run_groups", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestListRunGroupsAllowedWithScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_run_groups"}, ReadScopes: []string{"control_center_ansible"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newAnsibleRunner(b).Dispatch(context.Background(), "g", "list_run_groups", []byte(`{}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

func TestGetRunDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"get_run"}, ReadScopes: []string{"cves"}, // wrong scope
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}}
	_, err := newAnsibleRunner(b).Dispatch(context.Background(), "g", "get_run", []byte(`{"id":"101"}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

// validRunPayload is the exact closed full projection for get_run (cc_runs
// module.FullKeys) wrapped in the {correlation_id, run} envelope. It excludes
// every secret snapshot field (playbook_yaml, inventory_yaml, known_hosts,
// lease_digest, runner_id) by construction.
const validRunPayload = `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run":{` +
	`"id":"101","run_group_id":"42","playbook_id":"9","position":1,"status":"succeeded",` +
	`"playbook_name":"deploy-web","inventory_name":"prod","credential_name":"prod-ssh",` +
	`"credential_fingerprint":"ab12cd34","variable_audit":{},"secret_variable_names":[],` +
	`"host_limit":"web-01","check_mode":false,"timeout_seconds":600,"error_code":null,` +
	`"error_detail":null,"exit_status":0,"ok_count":5,"changed_count":1,"failed_count":0,` +
	`"unreachable_count":0,"stored_event_bytes":1024,"truncated":false,` +
	`"queued_at":"2026-07-01T00:00:00Z","started_at":"2026-07-01T00:00:01Z",` +
	`"completed_at":"2026-07-01T00:05:00Z","cancel_requested_at":null,` +
	`"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:05:00Z"}}`

func TestGetRunAllowedWithScope(t *testing.T) {
	payload := []byte(validRunPayload)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"get_run"}, ReadScopes: []string{"control_center_ansible"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: payload}
	out, err := newAnsibleRunner(b).Dispatch(context.Background(), "g", "get_run", []byte(`{"id":"101"}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

// TestGetRunSecretFieldRejected proves the closed output validator — wired
// into Runner.Dispatch as a second line of defense — rejects a backend
// response that is otherwise the valid full projection but leaks the
// lease_digest snapshot secret as an extra key. The runner must never hand
// this payload back to the caller, even with a fully granted scope.
func TestGetRunSecretFieldRejected(t *testing.T) {
	leaked := validRunPayload[:len(validRunPayload)-2] + `,"lease_digest":"deadbeefcafe"}}`
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"get_run"}, ReadScopes: []string{"control_center_ansible"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: []byte(leaked)}
	out, err := newAnsibleRunner(b).Dispatch(context.Background(), "g", "get_run", []byte(`{"id":"101"}`))
	if !errors.Is(err, ErrResponseRejected) {
		t.Fatalf("want ErrResponseRejected for leaked lease_digest, got out=%q err=%v", out, err)
	}
	if out != nil {
		t.Fatalf("leaked payload must not be returned, got %q", out)
	}
}

// TestGetRunGroupSecretFieldRejected mirrors TestGetRunSecretFieldRejected
// for get_run_group: a payload that is the valid full projection plus a
// leaked execution_payload (the encrypted, resolved-secrets column) must be
// rejected by the module's closed Validate, not returned to the caller.
func TestGetRunGroupSecretFieldRejected(t *testing.T) {
	validRunGroup := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run_group":{` +
		`"id":"42","status":"succeeded","execution_mode":"serial","failure_policy":"abort",` +
		`"inventory_id":"7","credential_id":"3","started_at":"2026-07-01T00:00:00Z",` +
		`"completed_at":"2026-07-01T00:05:00Z","created_at":"2026-07-01T00:00:00Z",` +
		`"concurrency_limit":5,"launch_snapshot":{},"cancel_requested_at":null,` +
		`"updated_at":"2026-07-01T00:05:00Z","runs":[]}}`
	leaked := validRunGroup[:len(validRunGroup)-2] + `,"execution_payload":"resolved-secret-blob"}}`
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"get_run_group"}, ReadScopes: []string{"control_center_ansible"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 64, BytesRemaining: 16 << 20,
	}, payload: []byte(leaked)}
	out, err := newAnsibleRunner(b).Dispatch(context.Background(), "g", "get_run_group", []byte(`{"id":"42"}`))
	if !errors.Is(err, ErrResponseRejected) {
		t.Fatalf("want ErrResponseRejected for leaked execution_payload, got out=%q err=%v", out, err)
	}
	if out != nil {
		t.Fatalf("leaked payload must not be returned, got %q", out)
	}
}
