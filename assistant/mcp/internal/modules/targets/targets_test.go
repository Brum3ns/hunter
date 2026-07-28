package targets

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

func TestListTargetsBuildsQuery(t *testing.T) {
	tl := find(t, "list_targets")
	if tl.Scope != "targets" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
	req, err := tl.Decode([]byte(`{"q":"*.example.com","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/targets?limit=10&q=%2A.example.com" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListTargetsNoParams(t *testing.T) {
	tl := find(t, "list_targets")
	req, _ := tl.Decode([]byte(`{}`))
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/targets" {
		t.Fatalf("path with no params: %s", call.Path)
	}
}

func TestGetTargetBuildsPath(t *testing.T) {
	tl := find(t, "get_target")
	req, err := tl.Decode([]byte(`{"id":"6570f1a2b3c4d5e6f7a8b9c0"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/targets/6570f1a2b3c4d5e6f7a8b9c0" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"bad id"}`)); err == nil {
		t.Fatal("bad id accepted")
	}
}

func TestListTargetsRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_targets")
	if _, err := tl.Decode([]byte(`{"q":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestListOutputValidation(t *testing.T) {
	tl := find(t, "list_targets")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"t1","host":"a.example.com","program":"acme","status_code":200,"title":"Home"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := []string{
		`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,"items":[{"id":"t1","host":"a","program":"p","status_code":200,"title":"t","EXTRA":1}]}`,
		`{"correlation_id":"not-a-uuid","count":1,"page":1,"limit":50,"items":[]}`,
		`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,"items":[],"x":1}`,
	}
	for _, b := range bad {
		if tl.Validate([]byte(b)) == nil {
			t.Fatalf("accepted invalid output: %s", b)
		}
	}
}

func TestGetOutputValidation(t *testing.T) {
	tl := find(t, "get_target")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","target":{` +
		`"id":"t1","host":"a","program":"p","status_code":200,"title":"t",` +
		`"url":"https://a","status_family":"2xx","webserver":"nginx","content_type":"text/html",` +
		`"port":443,"scheme":"https","tech":["nginx"],"seen_at":"2026-01-01","page_type":"login"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","target":{"id":"t1"}}`)) == nil {
		t.Fatal("partial target accepted")
	}
}
