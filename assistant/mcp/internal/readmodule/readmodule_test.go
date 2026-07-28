package readmodule

import (
	"regexp"
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

func spec() Spec {
	return Spec{
		ListTool: "list_things", GetTool: "get_thing", Scope: "things",
		BasePath: "/api/v1/assistant/machine/things", DetailKey: "thing",
		ListDesc: "List things.", GetDesc: "Get one thing.",
		ListFields: []ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "status", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "name"},
		FullKeys:    []string{"id", "name", "detail"},
	}
}

func find(t *testing.T, tools []tool.Tool, name string) tool.Tool {
	t.Helper()
	for _, x := range tools {
		if x.Name == name {
			return x
		}
	}
	t.Fatalf("tool %q not built", name)
	return tool.Tool{}
}

func TestBuildListRequest(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	if tl.Scope != "things" {
		t.Fatalf("scope %q", tl.Scope)
	}
	req, err := tl.Decode([]byte(`{"q":"*.example.com","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v %v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/things?limit=10&q=%2A.example.com" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListRejectsUnknownField(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	if _, err := tl.Decode([]byte(`{"q":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestListRejectsWrongType(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	if _, err := tl.Decode([]byte(`{"limit":"big"}`)); err == nil {
		t.Fatal("string limit accepted")
	}
}

func TestGetValidatesID(t *testing.T) {
	tl := find(t, Build(spec()), "get_thing")
	if _, err := tl.Decode([]byte(`{"id":"../etc"}`)); err == nil {
		t.Fatal("unsafe id accepted")
	}
	req, err := tl.Decode([]byte(`{"id":"abc123"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/things/abc123" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestGetHonorsCustomIDPattern(t *testing.T) {
	s := spec()
	s.IDPattern = regexp.MustCompile(`^[0-9]+$`)
	tl := find(t, Build(s), "get_thing")
	if _, err := tl.Decode([]byte(`{"id":"abc"}`)); err == nil {
		t.Fatal("non-numeric id accepted under numeric pattern")
	}
	if _, err := tl.Decode([]byte(`{"id":"42"}`)); err != nil {
		t.Fatalf("numeric id rejected: %v", err)
	}
}

func TestListOutputValidation(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"t1","name":"n"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	extra := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"t1","name":"n","EXTRA":1}]}`
	if tl.Validate([]byte(extra)) == nil {
		t.Fatal("extra item key accepted")
	}
}

func TestGetOutputValidation(t *testing.T) {
	tl := find(t, Build(spec()), "get_thing")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","thing":{"id":"t1","name":"n","detail":"d"}}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","thing":{"id":"t1","name":"n"}}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("missing full key accepted")
	}
}
