package programs

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

func TestListProgramsScope(t *testing.T) {
	tl := find(t, "list_programs")
	if tl.Scope != "programs" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListProgramsBuildsQueryWithFilter(t *testing.T) {
	tl := find(t, "list_programs")
	req, err := tl.Decode([]byte(`{"platforms":"hackerone,bugcrowd","status":"public","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/programs?limit=10&platforms=hackerone%2Cbugcrowd&status=public" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListProgramsAcceptsFreeTextQuery(t *testing.T) {
	tl := find(t, "list_programs")
	req, err := tl.Decode([]byte(`{"q":"acme asset:example.com"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/programs?q=acme+asset%3Aexample.com" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListProgramsRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_programs")
	if _, err := tl.Decode([]byte(`{"status":"public","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetProgramBuildsPath(t *testing.T) {
	tl := find(t, "get_program")
	req, err := tl.Decode([]byte(`{"id":"acme-corp"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/programs/acme-corp" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"bad id"}`)); err == nil {
		t.Fatal("bad id accepted")
	}
}

func TestListProgramsOutputValidation(t *testing.T) {
	tl := find(t, "list_programs")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"sid":"acme-corp","name":"Acme Corp","platform":"hackerone","public":true,"bounty_range":"Up to $5,000"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"sid":"acme-corp","name":"Acme Corp","platform":"hackerone","public":true,"bounty_range":"Up to $5,000","EXTRA":1}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output")
	}
}

func TestGetProgramOutputValidation(t *testing.T) {
	tl := find(t, "get_program")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","program":{` +
		`"sid":"acme-corp","name":"Acme Corp","platform":"hackerone","public":true,"bounty_range":"Up to $5,000",` +
		`"slug":"acme-corp","url":"https://hackerone.com/acme-corp","vdp":false,"bounty":true,` +
		`"bounty_min":100,"bounty_max":5000,"currency":"USD","reward_avg":250,"reward_max":5000,` +
		`"report_count":42,"reports_24h":1,"reports_7d":3,"reports_month":10,"avg_response_hrs":24,` +
		`"scope_count":2,"collaboration":false,"tags":["web"],"languages":["ruby"],` +
		`"scope":[{"asset":"example.com","type":"web"}],"out_of_scope":[]}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","program":{"sid":"acme-corp"}}`)) == nil {
		t.Fatal("partial program accepted")
	}
}

func TestListProgramsQDescribesDorkKeys(t *testing.T) {
	tl := find(t, "list_programs")
	var schema struct {
		Properties map[string]struct {
			Description string `json:"description"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(tl.InputSchema, &schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	desc := schema.Properties["q"].Description
	for _, key := range []string{"hall_of_fame", "avg_reward"} {
		if !strings.Contains(desc, key) {
			t.Fatalf("q description missing key %q: %s", key, desc)
		}
	}
}

func TestGetProgramDescriptionNonEmpty(t *testing.T) {
	tl := find(t, "get_program")
	if tl.Description == "" {
		t.Fatal("get_program description empty")
	}
}
