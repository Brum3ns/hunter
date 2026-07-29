package cc_runs

import (
	"strings"
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

func TestToolsReturnsOnlyGetRun(t *testing.T) {
	tools := (Module{}).Tools()
	if len(tools) != 1 {
		t.Fatalf("expected exactly 1 tool (get_run only), got %d: %+v", len(tools), tools)
	}
	if tools[0].Name != "get_run" {
		t.Fatalf("expected get_run, got %q", tools[0].Name)
	}
}

func find(t *testing.T, name string) tool.Tool {
	t.Helper()
	for _, tl := range (Module{}).Tools() {
		if tl.Name == name {
			return tl
		}
	}
	t.Fatalf("missing tool %s", name)
	return tool.Tool{}
}

func TestGetRunScope(t *testing.T) {
	tl := find(t, "get_run")
	if tl.Scope != "control_center_ansible" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestGetRunBuildsPathAndValidatesID(t *testing.T) {
	tl := find(t, "get_run")
	req, err := tl.Decode([]byte(`{"id":"42"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/runs/42" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"not-an-int"}`)); err == nil {
		t.Fatal("non-integer id accepted")
	}
}

func goodRunFullJSON() string {
	return `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run":{` +
		`"id":1,"run_group_id":1,"playbook_id":1,"position":0,"status":"succeeded",` +
		`"playbook_name":"Baseline","inventory_name":"Workers","credential_name":"Deploy",` +
		`"credential_fingerprint":"SHA256:abc","variable_audit":{},"secret_variable_names":[],` +
		`"host_limit":null,"check_mode":false,"timeout_seconds":3600,` +
		`"error_code":null,"error_detail":null,"exit_status":0,` +
		`"ok_count":1,"changed_count":0,"failed_count":0,"unreachable_count":0,` +
		`"stored_event_bytes":0,"truncated":false,` +
		`"queued_at":"2026-01-01","started_at":"2026-01-01","completed_at":"2026-01-01","cancel_requested_at":null,` +
		`"created_at":"2026-01-01","updated_at":"2026-01-01"}}`
}

func TestGetRunOutputValidation(t *testing.T) {
	tl := find(t, "get_run")
	if err := tl.Validate([]byte(goodRunFullJSON())); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run":{"id":1}}`)) == nil {
		t.Fatal("partial run accepted")
	}
	for _, forbidden := range []string{"playbook_yaml", "inventory_yaml", "known_hosts", "lease_digest", "runner_id"} {
		leaked := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run":{` +
			`"id":1,"run_group_id":1,"playbook_id":1,"position":0,"status":"succeeded",` +
			`"playbook_name":"Baseline","inventory_name":"Workers","credential_name":"Deploy",` +
			`"credential_fingerprint":"SHA256:abc","variable_audit":{},"secret_variable_names":[],` +
			`"host_limit":null,"check_mode":false,"timeout_seconds":3600,` +
			`"error_code":null,"error_detail":null,"exit_status":0,` +
			`"ok_count":1,"changed_count":0,"failed_count":0,"unreachable_count":0,` +
			`"stored_event_bytes":0,"truncated":false,` +
			`"queued_at":"2026-01-01","started_at":"2026-01-01","completed_at":"2026-01-01","cancel_requested_at":null,` +
			`"created_at":"2026-01-01","updated_at":"2026-01-01","` + forbidden + `":"x"}}`
		if tl.Validate([]byte(leaked)) == nil {
			t.Fatalf("accepted output leaking %s", forbidden)
		}
	}
}

func TestGetRunDescriptionMentionsExcludedFields(t *testing.T) {
	tl := find(t, "get_run")
	if tl.Description == "" {
		t.Fatal("get_run description empty")
	}
	for _, want := range []string{"playbook_yaml", "inventory_yaml", "known_hosts", "lease_digest", "runner_id"} {
		if !strings.Contains(tl.Description, want) {
			t.Fatalf("get_run description missing %q: %s", want, tl.Description)
		}
	}
}
