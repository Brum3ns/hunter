package cc_run_events

import (
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

func TestToolsReturnsOnlyListRunEvents(t *testing.T) {
	tools := (Module{}).Tools()
	if len(tools) != 1 {
		t.Fatalf("expected exactly 1 tool (list_run_events only), got %d: %+v", len(tools), tools)
	}
	if tools[0].Name != "list_run_events" {
		t.Fatalf("expected list_run_events, got %q", tools[0].Name)
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

func TestListRunEventsScope(t *testing.T) {
	tl := find(t, "list_run_events")
	if tl.Scope != "control_center_ansible" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListRunEventsBuildsQueryWithRunIDAndCursor(t *testing.T) {
	tl := find(t, "list_run_events")
	req, err := tl.Decode([]byte(`{"run_id":42,"after_counter":10,"limit":5}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/run_events?after_counter=10&limit=5&run_id=42" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListRunEventsRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_run_events")
	if _, err := tl.Decode([]byte(`{"run_id":1,"evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestListRunEventsRejectsWrongTypeRunID(t *testing.T) {
	tl := find(t, "list_run_events")
	if _, err := tl.Decode([]byte(`{"run_id":"not-an-int"}`)); err == nil {
		t.Fatal("string run_id accepted")
	}
}

func TestListRunEventsOutputValidation(t *testing.T) {
	tl := find(t, "list_run_events")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":100,` +
		`"items":[{"id":1,"counter":1,"event_uuid":"u1","parent_uuid":null,"event_type":"runner_on_ok",` +
		`"play":"p","task":"t","host":"h","event_time":"2026-01-01","stdout":"ok","event_data":{},` +
		`"truncated":false,"created_at":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":100,` +
		`"items":[{"id":1,"counter":1,"event_uuid":"u1","parent_uuid":null,"event_type":"runner_on_ok",` +
		`"play":"p","task":"t","host":"h","event_time":"2026-01-01","stdout":"ok","event_data":{},` +
		`"truncated":false,"created_at":"2026-01-01","runner_id":1}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output (runner_id leaked)")
	}
	tooMany := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":100,` +
		`"items":` + itemsN(101) + `}`
	if tl.Validate([]byte(tooMany)) == nil {
		t.Fatal("accepted more than 100 items")
	}
}

func itemsN(n int) string {
	item := `{"id":1,"counter":1,"event_uuid":"u1","parent_uuid":null,"event_type":"runner_on_ok",` +
		`"play":"p","task":"t","host":"h","event_time":"2026-01-01","stdout":"ok","event_data":{},` +
		`"truncated":false,"created_at":"2026-01-01"}`
	out := "["
	for i := 0; i < n; i++ {
		if i > 0 {
			out += ","
		}
		out += item
	}
	return out + "]"
}
