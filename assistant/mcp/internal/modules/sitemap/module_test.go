package sitemap

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

func TestListEndpointsScope(t *testing.T) {
	tl := find(t, "list_endpoints")
	if tl.Scope != "sitemap" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListEndpointsBuildsQueryWithFilter(t *testing.T) {
	tl := find(t, "list_endpoints")
	req, err := tl.Decode([]byte(`{"methods":"GET,POST","status":"4","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/sitemap/endpoints?limit=10&methods=GET%2CPOST&status=4" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListEndpointsAcceptsFreeTextQuery(t *testing.T) {
	tl := find(t, "list_endpoints")
	req, err := tl.Decode([]byte(`{"q":"path:/admin status:200"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/sitemap/endpoints?q=path%3A%2Fadmin+status%3A200" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListEndpointsRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_endpoints")
	if _, err := tl.Decode([]byte(`{"path":"/x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetEndpointBuildsPath(t *testing.T) {
	tl := find(t, "get_endpoint")
	req, err := tl.Decode([]byte(`{"id":"123"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/sitemap/endpoints/123" {
		t.Fatalf("path: %s", call.Path)
	}
	for _, bad := range []string{"0", "007", "bad id", "-5", "12.3"} {
		if _, err := tl.Decode([]byte(`{"id":"` + bad + `"}`)); err == nil {
			t.Fatalf("bad id accepted: %s", bad)
		}
	}
}

func TestListEndpointsOutputValidation(t *testing.T) {
	tl := find(t, "list_endpoints")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":123,"url":"https://example.com/a","path":"/a","method":"GET","status_code":200}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":123,"url":"https://example.com/a","path":"/a","method":"GET","status_code":200,"EXTRA":1}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output")
	}
}

func TestGetEndpointOutputValidation(t *testing.T) {
	tl := find(t, "get_endpoint")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","endpoint":{` +
		`"id":123,"url":"https://example.com/a","path":"/a","method":"GET","status_code":200,` +
		`"origin":"https://example.com","content_type":"text/html","content_length":512,` +
		`"first_seen_at":"2024-01-01","last_seen_at":"2026-01-01",` +
		`"program":"acme","host":"example.com","scheme":"https","port":443}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","endpoint":{"id":123}}`)) == nil {
		t.Fatal("partial endpoint accepted")
	}
}

func TestListEndpointsQDescribesDorkKeys(t *testing.T) {
	tl := find(t, "list_endpoints")
	var schema struct {
		Properties map[string]struct {
			Description string `json:"description"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(tl.InputSchema, &schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	desc := schema.Properties["q"].Description
	for _, key := range []string{"has_query", "root"} {
		if !strings.Contains(desc, key) {
			t.Fatalf("q description missing key %q: %s", key, desc)
		}
	}
}

func TestGetEndpointDescriptionNonEmpty(t *testing.T) {
	tl := find(t, "get_endpoint")
	if tl.Description == "" {
		t.Fatal("get_endpoint description empty")
	}
}
