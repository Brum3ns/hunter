package runner

import (
	"context"
	"errors"
	"testing"

	ccRunGroups "hunter.local/assistant/mcp/internal/modules/cc_run_groups"
	ccRuns "hunter.local/assistant/mcp/internal/modules/cc_runs"
	ccwrite "hunter.local/assistant/mcp/internal/modules/ccwrite"
	targets "hunter.local/assistant/mcp/internal/modules/targets"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/tool"
)

func moduleRunner(b Backend, modules ...tool.Module) *Runner {
	registry := NewRegistry()
	for _, module := range modules {
		registry.Add(module)
	}
	return New(b, registry, redact.NewChecker(64<<10))
}

func TestReviewedListDispatchesWithoutGrantState(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := &fakeBackend{payload: payload}
	out, err := moduleRunner(b, targets.Module{}).Dispatch(
		context.Background(), "list_targets", []byte(`{"q":"example.com"}`),
	)
	if err != nil || string(out) != string(payload) {
		t.Fatalf("Dispatch: out=%q err=%v", out, err)
	}
	if b.method != "GET" || b.path != "/api/v1/assistant/machine/targets?q=example.com" {
		t.Fatalf("fixed call=%s %s", b.method, b.path)
	}
}

func TestReviewedWriteDispatchesWithoutGrantState(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","receipt":{"receipt_id":"3b241101-e2bb-4255-8caf-4136c566a963","tool":"create_whiterabbit_template","status":"created","target":{"type":"whiterabbit_template","id":"1"},"human_user_id":1,"turn_id":null,"idempotency_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","replayed":false,"occurred_at":"2026-08-19T00:00:00Z"}}`)
	b := &fakeBackend{payload: payload}
	out, err := moduleRunner(b, ccwrite.Module{}).Dispatch(
		context.Background(),
		"create_whiterabbit_template",
		[]byte(`{"template":{"name":"httpx proof","kind":"cmdscript","commands":[{"command":"httpx"}]}}`),
	)
	if err != nil || string(out) != string(payload) {
		t.Fatalf("Dispatch: out=%q err=%v", out, err)
	}
	if b.method != "POST" || b.path != "/api/v1/assistant/machine/control_center/templates" {
		t.Fatalf("fixed call=%s %s", b.method, b.path)
	}
}

func TestUnknownInputStillFailsBeforeBackendIO(t *testing.T) {
	b := &fakeBackend{payload: []byte(`{}`)}
	_, err := moduleRunner(b, targets.Module{}).Dispatch(
		context.Background(), "list_targets", []byte(`{"method":"DELETE"}`),
	)
	if !errors.Is(err, ErrInvalidInput) || b.calls != 0 {
		t.Fatalf("err=%v calls=%d", err, b.calls)
	}
}

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

func TestClosedRunOutputStillRejectsSecretSnapshotFields(t *testing.T) {
	leaked := validRunPayload[:len(validRunPayload)-2] + `,"lease_digest":"deadbeefcafe"}}`
	b := &fakeBackend{payload: []byte(leaked)}
	out, err := moduleRunner(b, ccRunGroups.Module{}, ccRuns.Module{}).Dispatch(
		context.Background(), "get_run", []byte(`{"id":"101"}`),
	)
	if !errors.Is(err, ErrResponseRejected) || out != nil {
		t.Fatalf("out=%q err=%v", out, err)
	}
}
