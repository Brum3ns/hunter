package cves

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

func TestListCvesScope(t *testing.T) {
	tl := find(t, "list_cves")
	if tl.Scope != "cves" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListCvesBuildsQueryWithFilter(t *testing.T) {
	tl := find(t, "list_cves")
	req, err := tl.Decode([]byte(`{"ecosystem":"npm","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/cves?ecosystem=npm&limit=10" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListCvesRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_cves")
	if _, err := tl.Decode([]byte(`{"q":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetCveBuildsPath(t *testing.T) {
	tl := find(t, "get_cve")
	req, err := tl.Decode([]byte(`{"id":"CVE-2024-1234"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/cves/CVE-2024-1234" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"bad id"}`)); err == nil {
		t.Fatal("bad id accepted")
	}
}

func TestListCvesOutputValidation(t *testing.T) {
	tl := find(t, "list_cves")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"CVE-2024-1234","summary":"s","severity_level":"high","severity_score":7.5,"has_fix":true,"modified":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"CVE-2024-1234","summary":"s","severity_level":"high","severity_score":7.5,"has_fix":true,"modified":"2026-01-01","EXTRA":1}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output")
	}
}

func TestGetCveOutputValidation(t *testing.T) {
	tl := find(t, "get_cve")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","cve":{` +
		`"id":"CVE-2024-1234","summary":"s","severity_level":"high","severity_score":7.5,"has_fix":true,"modified":"2026-01-01",` +
		`"details":"d","aliases":["GHSA-xxxx-yyyy-zzzz"],"published":"2024-01-01","withdrawn":null,"cwe_ids":["CWE-79"],` +
		`"ecosystems":["npm"],"languages":["javascript"],"vendors":["acme"],"tags":["xss"],` +
		`"affected":[{"ecosystem":"npm","package":"foo"}],"references":["https://example.com/advisory"],` +
		`"chain":{"fixed_in":"1.2.3"},"osv_id":"GHSA-xxxx-yyyy-zzzz","first_seen_at":"2024-01-01","last_synced_at":"2026-01-01"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","cve":{"id":"CVE-2024-1234"}}`)) == nil {
		t.Fatal("partial cve accepted")
	}
}
