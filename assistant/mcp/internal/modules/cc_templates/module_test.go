package cc_templates

import (
	"encoding/json"
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
		`"items":[{"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"lock_version":0,"created_by":"operator","updated_at":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"lock_version":0,"created_by":"operator","updated_at":"2026-01-01","credential":"x"}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output")
	}
}

func TestGetTemplateOutputValidation(t *testing.T) {
	tl := find(t, "get_template")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{` +
		`"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"lock_version":0,"created_by":"operator","updated_at":"2026-01-01",` +
		`"output":"json","commands":[{"command":"curl","args":[],"operator":""}],"target":{"type":"host","separator":null,"output":null},"created_at":"2026-01-01"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{"id":1}}`)) == nil {
		t.Fatal("partial template accepted")
	}
	leaked := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{` +
		`"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"lock_version":0,"created_by":"operator","updated_at":"2026-01-01",` +
		`"output":"json","commands":[],"target":null,"created_at":"2026-01-01","credential":"x"}}`
	if tl.Validate([]byte(leaked)) == nil {
		t.Fatal("accepted output with an unknown field")
	}
	nestedLeak := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{` +
		`"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":["recon"],"lock_version":0,"created_by":"operator","updated_at":"2026-01-01",` +
		`"output":"json","commands":[{"command":"curl","args":[],"operator":"","credential":"leak"}],"target":null,"created_at":"2026-01-01"}}`
	if tl.Validate([]byte(nestedLeak)) == nil {
		t.Fatal("accepted unknown nested command field")
	}
}

func TestGetTemplateRejectsMalformedNestedCommandAndTargetValues(t *testing.T) {
	tl := find(t, "get_template")
	base := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{` +
		`"id":1,"name":"probe","kind":"cmdscript","description":"d","tags":[],"lock_version":0,"created_by":"operator","updated_at":"2026-01-01",` +
		`"output":"json","commands":[{"command":"httpx","args":[],"operator":""}],` +
		`"target":{"type":"file","separator":"newline","output":"__TARGET_FILE__"},"created_at":"2026-01-01"}}`
	for _, malformed := range []string{
		strings.Replace(base, `"args":[]`, `"args":[{"arbitrary":true}]`, 1),
		strings.Replace(base, `"separator":"newline"`, `"separator":42`, 1),
	} {
		if tl.Validate([]byte(malformed)) == nil {
			t.Fatalf("accepted malformed nested template: %s", malformed)
		}
	}
}

func TestListTemplatesKindDescribesValues(t *testing.T) {
	tl := find(t, "list_templates")
	var schema struct {
		Properties map[string]struct {
			Description string `json:"description"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(tl.InputSchema, &schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	desc := schema.Properties["kind"].Description
	for _, want := range []string{"cmdscript", "workflow"} {
		if !strings.Contains(desc, want) {
			t.Fatalf("kind description missing %q: %s", want, desc)
		}
	}
}

func TestGetTemplateDescriptionNonEmpty(t *testing.T) {
	tl := find(t, "get_template")
	if tl.Description == "" {
		t.Fatal("get_template description empty")
	}
}
