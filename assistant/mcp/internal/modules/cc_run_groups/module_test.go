package cc_run_groups

import (
	"strings"
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

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

func TestListRunGroupsScope(t *testing.T) {
	tl := find(t, "list_run_groups")
	if tl.Scope != "control_center_ansible" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListRunGroupsBuildsQuery(t *testing.T) {
	tl := find(t, "list_run_groups")
	req, err := tl.Decode([]byte(`{"limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/run_groups?limit=10" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestGetRunGroupBuildsPathAndValidatesID(t *testing.T) {
	tl := find(t, "get_run_group")
	req, err := tl.Decode([]byte(`{"id":"42"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/run_groups/42" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"not-an-int"}`)); err == nil {
		t.Fatal("non-integer id accepted")
	}
}

func TestListRunGroupsOutputValidation(t *testing.T) {
	tl := find(t, "list_run_groups")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"status":"queued","execution_mode":"sequential","failure_policy":"stop",` +
		`"inventory_id":null,"credential_id":null,"started_at":null,"completed_at":null,"created_at":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"status":"queued","execution_mode":"sequential","failure_policy":"stop",` +
		`"inventory_id":null,"credential_id":null,"started_at":null,"completed_at":null,"created_at":"2026-01-01","execution_payload":"x"}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output (execution_payload leaked in summary)")
	}
}

func TestGetRunGroupOutputValidation(t *testing.T) {
	tl := find(t, "get_run_group")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run_group":{` +
		`"id":1,"status":"queued","execution_mode":"sequential","failure_policy":"stop",` +
		`"inventory_id":null,"credential_id":null,"started_at":null,"completed_at":null,"created_at":"2026-01-01",` +
		`"concurrency_limit":1,"launch_snapshot":{},"cancel_requested_at":null,"updated_at":"2026-01-01","runs":[]}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run_group":{"id":1}}`)) == nil {
		t.Fatal("partial run_group accepted")
	}
	leaked := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","run_group":{` +
		`"id":1,"status":"queued","execution_mode":"sequential","failure_policy":"stop",` +
		`"inventory_id":null,"credential_id":null,"started_at":null,"completed_at":null,"created_at":"2026-01-01",` +
		`"concurrency_limit":1,"launch_snapshot":{},"cancel_requested_at":null,"updated_at":"2026-01-01","runs":[],` +
		`"execution_payload":"secret"}}`
	if tl.Validate([]byte(leaked)) == nil {
		t.Fatal("accepted output leaking execution_payload")
	}
}

func TestListRunGroupsDescriptionNonEmpty(t *testing.T) {
	tl := find(t, "list_run_groups")
	if tl.Description == "" {
		t.Fatal("list_run_groups description empty")
	}
}

func TestGetRunGroupDescriptionMentionsExecutionPayload(t *testing.T) {
	tl := find(t, "get_run_group")
	if tl.Description == "" {
		t.Fatal("get_run_group description empty")
	}
	if !strings.Contains(tl.Description, "execution_payload") {
		t.Fatalf("get_run_group description missing %q: %s", "execution_payload", tl.Description)
	}
}
