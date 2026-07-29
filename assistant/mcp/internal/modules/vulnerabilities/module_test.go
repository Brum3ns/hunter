package vulnerabilities

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

func TestListVulnerabilitiesScope(t *testing.T) {
	tl := find(t, "list_vulnerabilities")
	if tl.Scope != "vulnerabilities" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListVulnerabilitiesBuildsQueryWithFilter(t *testing.T) {
	tl := find(t, "list_vulnerabilities")
	req, err := tl.Decode([]byte(`{"program":"acme","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/vulnerabilities?limit=10&program=acme" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListVulnerabilitiesRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_vulnerabilities")
	if _, err := tl.Decode([]byte(`{"q":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetVulnerabilityBuildsPath(t *testing.T) {
	tl := find(t, "get_vulnerability")
	req, err := tl.Decode([]byte(`{"id":"60f7c2d2b1a2c3d4e5f6a7b8"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/vulnerabilities/60f7c2d2b1a2c3d4e5f6a7b8" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"bad id"}`)); err == nil {
		t.Fatal("bad id accepted")
	}
}

func TestListVulnerabilitiesOutputValidation(t *testing.T) {
	tl := find(t, "list_vulnerabilities")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"60f7c2d2b1a2c3d4e5f6a7b8","name":"Reflected XSS","severity":"high","status":"triaged","program":"acme"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"60f7c2d2b1a2c3d4e5f6a7b8","name":"Reflected XSS","severity":"high","status":"triaged","program":"acme","EXTRA":1}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output")
	}
}

func TestGetVulnerabilityOutputValidation(t *testing.T) {
	tl := find(t, "get_vulnerability")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","vulnerability":{` +
		`"id":"60f7c2d2b1a2c3d4e5f6a7b8","name":"Reflected XSS","severity":"high","status":"triaged","program":"acme",` +
		`"type":"xss","cwe":"CWE-79","tags":["xss"],"tool":"burp","asset":"web","date":"2026-01-01",` +
		`"description":"d","impact":"i","host":"app.acme.test","url":"https://app.acme.test/x","ip":"10.0.0.1","port":443,` +
		`"submitted":"2026-01-01","status_updated_at":"2026-01-02","confidence":"confirmed"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","vulnerability":{"id":"60f7c2d2b1a2c3d4e5f6a7b8"}}`)) == nil {
		t.Fatal("partial vulnerability accepted")
	}
	// Secret/PII fields must never validate as accepted output shape.
	leaked := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","vulnerability":{` +
		`"id":"60f7c2d2b1a2c3d4e5f6a7b8","name":"Reflected XSS","severity":"high","status":"triaged","program":"acme",` +
		`"type":"xss","cwe":"CWE-79","tags":["xss"],"tool":"burp","asset":"web","date":"2026-01-01",` +
		`"description":"d","impact":"i","host":"app.acme.test","url":"https://app.acme.test/x","ip":"10.0.0.1","port":443,` +
		`"submitted":"2026-01-01","status_updated_at":"2026-01-02","confidence":"confirmed","status_updated_by":"leak"}}`
	if tl.Validate([]byte(leaked)) == nil {
		t.Fatal("accepted output with a secret/PII field")
	}
}

func TestListVulnerabilitiesQDescribesDorkKeys(t *testing.T) {
	tl := find(t, "list_vulnerabilities")
	var schema struct {
		Properties map[string]struct {
			Description string `json:"description"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(tl.InputSchema, &schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	desc := schema.Properties["q"].Description
	if !strings.Contains(desc, "confidence") {
		t.Fatalf("q description missing key %q: %s", "confidence", desc)
	}
}

func TestGetVulnerabilityDescriptionNonEmpty(t *testing.T) {
	tl := find(t, "get_vulnerability")
	if tl.Description == "" {
		t.Fatal("get_vulnerability description empty")
	}
}
