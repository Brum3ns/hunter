package cc_jobs

import (
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

func TestListJobsScope(t *testing.T) {
	tl := find(t, "list_jobs")
	if tl.Scope != "control_center_jobs" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListJobsBuildsQueryWithFilter(t *testing.T) {
	tl := find(t, "list_jobs")
	req, err := tl.Decode([]byte(`{"status":"failed","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/jobs?limit=10&status=failed" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListJobsRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_jobs")
	if _, err := tl.Decode([]byte(`{"status":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetJobBuildsPath(t *testing.T) {
	tl := find(t, "get_job")
	req, err := tl.Decode([]byte(`{"id":"42"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/control_center/jobs/42" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"not-an-int"}`)); err == nil {
		t.Fatal("non-integer id accepted")
	}
}

func TestListJobsOutputValidation(t *testing.T) {
	tl := find(t, "list_jobs")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"template_name":"probe","status":"succeeded","queue_name":"test","target_count":3,"exit_status":0,"created_at":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"template_name":"probe","status":"succeeded","queue_name":"test","target_count":3,"exit_status":0,"created_at":"2026-01-01","selections":[]}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output (selections leaked)")
	}
}

func TestGetJobOutputValidation(t *testing.T) {
	tl := find(t, "get_job")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","job":{` +
		`"id":1,"template_name":"probe","status":"succeeded","queue_name":"test","target_count":3,"exit_status":0,"created_at":"2026-01-01",` +
		`"stdout":"ok","stderr":"","updated_at":"2026-01-01"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","job":{"id":1}}`)) == nil {
		t.Fatal("partial job accepted")
	}
	for _, forbidden := range []string{"template_snapshot", "selections", "manual_targets", "idempotency_key"} {
		leaked := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","job":{` +
			`"id":1,"template_name":"probe","status":"succeeded","queue_name":"test","target_count":3,"exit_status":0,"created_at":"2026-01-01",` +
			`"stdout":"ok","stderr":"","updated_at":"2026-01-01","` + forbidden + `":"x"}}`
		if tl.Validate([]byte(leaked)) == nil {
			t.Fatalf("accepted output leaking %s", forbidden)
		}
	}
}
