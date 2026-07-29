package cc_templates

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

func TestListTemplatesScope(t *testing.T) {
	tl := find(t, "list_templates")
	if tl.Scope != "control_center_templates" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListTemplatesBuildsQueryWithFilter(t *testing.T) {
	tl := find(t, "list_templates")
	req, err := tl.Decode([]byte(`{"kind":"workflow","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/templates?kind=workflow&limit=10" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListTemplatesRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_templates")
	if _, err := tl.Decode([]byte(`{"kind":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetTemplateBuildsPath(t *testing.T) {
	tl := find(t, "get_template")
	req, err := tl.Decode([]byte(`{"id":"42"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/control_center/templates/42" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"not-an-int"}`)); err == nil {
		t.Fatal("non-integer id accepted")
	}
	if _, err := tl.Decode([]byte(`{"id":"0"}`)); err == nil {
		t.Fatal("zero id accepted")
	}
}

func TestListTemplatesOutputValidation(t *testing.T) {
	tl := find(t, "list_templates")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"updated_at":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"updated_at":"2026-01-01","created_by":"x"}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output (created_by leaked)")
	}
}

func TestGetTemplateOutputValidation(t *testing.T) {
	tl := find(t, "get_template")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{` +
		`"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"updated_at":"2026-01-01",` +
		`"output":"json","commands":[{"command":"curl","args":[]}],"target":{"type":"host"},"created_at":"2026-01-01"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{"id":1}}`)) == nil {
		t.Fatal("partial template accepted")
	}
	leaked := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{` +
		`"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"updated_at":"2026-01-01",` +
		`"output":"json","commands":[],"target":null,"created_at":"2026-01-01","created_by":"x"}}`
	if tl.Validate([]byte(leaked)) == nil {
		t.Fatal("accepted output leaking created_by")
	}
}
