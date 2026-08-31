package chat

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const pinnedCodexVersion = "codex-cli 0.144.4"

type contractToolFixture struct {
	name       string
	properties map[string]string
	required   []string
}

// TestRealCodexEnforcesApprovedHunterMCPBoundary is intentionally a
// process-level contract. Unit tests over argv cannot prove what the pinned CLI
// presents to a model after feature defaults and MCP discovery are applied.
func TestRealCodexEnforcesApprovedHunterMCPBoundary(t *testing.T) {
	codexBin := exactPinnedCodex(t)

	providerRequests := make(chan map[string]any, 2)
	var providerCalls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/responses" {
			http.NotFound(w, r)
			return
		}

		var body map[string]any
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20))
		if err := decoder.Decode(&body); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		call := providerCalls.Add(1)
		if call > 2 {
			http.Error(w, "unexpected retry", http.StatusConflict)
			return
		}
		providerRequests <- body

		w.Header().Set("Content-Type", "text/event-stream")
		if call == 1 {
			_, _ = fmt.Fprint(w, toolSearchContractSSE())
			return
		}
		_, _ = fmt.Fprint(w, finalContractSSE())
	}))
	t.Cleanup(provider.Close)

	var methodsMu sync.Mutex
	var mcpMethods []string
	mcp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/mcp" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer schema-mcp-token" ||
			r.Header.Get("X-Hunter-Turn-Grant") != "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		var request struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Method  string          `json:"method"`
			Params  json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		methodsMu.Lock()
		mcpMethods = append(mcpMethods, request.Method)
		methodsMu.Unlock()

		switch request.Method {
		case "initialize":
			var params struct {
				ProtocolVersion string `json:"protocolVersion"`
			}
			_ = json.Unmarshal(request.Params, &params)
			writeJSON(w, map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(request.ID),
				"result": map[string]any{
					"protocolVersion": params.ProtocolVersion,
					"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
					"serverInfo":      map[string]string{"name": "hunter-contract", "version": "1.0.0"},
				},
			})
		case "notifications/initialized":
			w.WriteHeader(http.StatusAccepted)
		case "tools/list":
			writeJSON(w, map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(request.ID),
				"result":  map[string]any{"tools": fakeReviewedMCPTools()},
			})
		default:
			writeJSON(w, map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(request.ID),
				"error":   map[string]any{"code": -32601, "message": "method not found"},
			})
		}
	}))
	t.Cleanup(mcp.Close)

	codexHome := t.TempDir()
	workingDir := t.TempDir()
	allowedTools := []string{
		"list_targets", "get_target", "list_cves", "get_cve",
		"list_vulnerabilities", "get_vulnerability", "list_endpoints", "get_endpoint",
		"list_programs", "get_program", "list_templates", "get_template",
		"list_jobs", "get_job", "list_playbooks", "get_playbook",
		"list_run_groups", "get_run_group", "get_run", "list_run_events",
		"create_whiterabbit_template", "create_ansible_playbook",
		"edit_whiterabbit_template", "edit_ansible_playbook",
	}
	inv := buildInvocation(Config{
		CodexHome:    codexHome,
		WorkingDir:   workingDir,
		MCPURL:       mcp.URL + "/mcp",
		MCPToken:     "schema-mcp-token",
		AllowedTools: allowedTools,
		SystemPrompt: "Use only the reviewed Hunter tools.",
	}, Request{Prompt: "Reply with the single word captured."})

	providerConfig := []string{
		"--config", `model="gpt-5.4"`,
		"--config", `model_provider="hunter_contract"`,
		"--config", "model_providers.hunter_contract.name=" + tomlString("Hunter contract provider"),
		"--config", "model_providers.hunter_contract.base_url=" + tomlString(provider.URL+"/v1"),
		"--config", `model_providers.hunter_contract.wire_api="responses"`,
		"--config", "model_providers.hunter_contract.requires_openai_auth=false",
		"--config", "model_providers.hunter_contract.request_max_retries=0",
		"--config", "model_providers.hunter_contract.stream_max_retries=0",
		"--config", "model_providers.hunter_contract.supports_websockets=false",
	}
	args := append([]string{}, inv.Args[:len(inv.Args)-1]...)
	args = append(args, providerConfig...)
	args = append(args, inv.Args[len(inv.Args)-1])

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, codexBin, args...)
	cmd.Env = inv.Env
	cmd.Dir = workingDir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("real %s invocation failed: %v\nstdout:\n%s\nstderr:\n%s", pinnedCodexVersion, err, stdout.String(), stderr.String())
	}

	if got := providerCalls.Load(); got != 2 {
		t.Fatalf("real Codex made %d provider requests, want 2", got)
	}
	firstRequest := <-providerRequests
	secondRequest := <-providerRequests
	methodsMu.Lock()
	gotMethods := slices.Clone(mcpMethods)
	methodsMu.Unlock()
	if !slices.Equal(gotMethods, []string{"initialize", "notifications/initialized", "tools/list"}) {
		t.Fatalf("unexpected MCP discovery sequence: %v", gotMethods)
	}

	gotBuiltins, gotNames := topLevelToolContracts(t, firstRequest)
	wantNames := []string{
		"apply_patch",
		"list_mcp_resource_templates",
		"list_mcp_resources",
		"read_mcp_resource",
		"request_user_input",
		"tool_search",
		"update_plan",
		"view_image",
	}
	if !slices.Equal(gotNames, wantNames) {
		t.Fatalf("Codex-owned model-visible tool names drifted\n got: %v\nwant: %v", gotNames, wantNames)
	}
	wantBuiltins := []string{
		`{"execution":"client","parameters":{"additionalProperties":false,"properties":{"limit":{"type":"number"},"query":{"type":"string"}},"required":["query"],"type":"object"},"type":"tool_search"}`,
		`{"format":{"definition_sha256":"d6367f4826ed608c424b0a308f3d6163527df63c22513d089b91863552f8bfeb","syntax":"lark","type":"grammar"},"name":"apply_patch","type":"custom"}`,
		`{"name":"list_mcp_resource_templates","parameters":{"additionalProperties":false,"properties":{"cursor":{"type":"string"},"server":{"type":"string"}},"type":"object"},"strict":false,"type":"function"}`,
		`{"name":"list_mcp_resources","parameters":{"additionalProperties":false,"properties":{"cursor":{"type":"string"},"server":{"type":"string"}},"type":"object"},"strict":false,"type":"function"}`,
		`{"name":"read_mcp_resource","parameters":{"additionalProperties":false,"properties":{"server":{"type":"string"},"uri":{"type":"string"}},"required":["server","uri"],"type":"object"},"strict":false,"type":"function"}`,
		`{"name":"request_user_input","parameters":{"additionalProperties":false,"properties":{"autoResolutionMs":{"type":"number"},"questions":{"items":{"additionalProperties":false,"properties":{"header":{"type":"string"},"id":{"type":"string"},"options":{"items":{"additionalProperties":false,"properties":{"description":{"type":"string"},"label":{"type":"string"}},"required":["label","description"],"type":"object"},"type":"array"},"question":{"type":"string"}},"required":["id","header","question","options"],"type":"object"},"type":"array"}},"required":["questions"],"type":"object"},"strict":false,"type":"function"}`,
		`{"name":"update_plan","parameters":{"additionalProperties":false,"properties":{"explanation":{"type":"string"},"plan":{"items":{"additionalProperties":false,"properties":{"status":{"enum":["pending","in_progress","completed"],"type":"string"},"step":{"type":"string"}},"required":["step","status"],"type":"object"},"type":"array"}},"required":["plan"],"type":"object"},"strict":false,"type":"function"}`,
		`{"name":"view_image","parameters":{"additionalProperties":false,"properties":{"detail":{"enum":["high","original"],"type":"string"},"path":{"type":"string"}},"required":["path"],"type":"object"},"strict":false,"type":"function"}`,
	}
	if !slices.Equal(gotBuiltins, wantBuiltins) {
		t.Fatalf("Codex-owned model-visible tool schemas drifted\n got: %q\nwant: %q", gotBuiltins, wantBuiltins)
	}
	assertOnlyHunterToolSource(t, firstRequest)

	searchOutput := findToolSearchOutput(t, secondRequest, "hunter-catalog")
	if searchOutput["status"] != "completed" || searchOutput["execution"] != "client" {
		t.Fatalf("unexpected Hunter tool-search outcome: %#v", searchOutput)
	}
	gotContracts, gotHunterNames := outboundToolContracts(t, map[string]any{"tools": searchOutput["tools"]})
	wantHunterNames := []string{
		"mcp__hunter__create_ansible_playbook",
		"mcp__hunter__create_whiterabbit_template",
		"mcp__hunter__edit_ansible_playbook",
		"mcp__hunter__edit_whiterabbit_template",
		"mcp__hunter__get_cve",
		"mcp__hunter__get_endpoint",
		"mcp__hunter__get_job",
		"mcp__hunter__get_playbook",
		"mcp__hunter__get_program",
		"mcp__hunter__get_run",
		"mcp__hunter__get_run_group",
		"mcp__hunter__get_target",
		"mcp__hunter__get_template",
		"mcp__hunter__get_vulnerability",
		"mcp__hunter__list_cves",
		"mcp__hunter__list_endpoints",
		"mcp__hunter__list_jobs",
		"mcp__hunter__list_playbooks",
		"mcp__hunter__list_programs",
		"mcp__hunter__list_run_events",
		"mcp__hunter__list_run_groups",
		"mcp__hunter__list_targets",
		"mcp__hunter__list_templates",
		"mcp__hunter__list_vulnerabilities",
	}
	if !slices.Equal(gotHunterNames, wantHunterNames) {
		t.Fatalf("deferred Hunter tool names drifted\n got: %v\nwant: %v", gotHunterNames, wantHunterNames)
	}

	wantContracts := []string{
		"mcp__hunter__create_ansible_playbook|object|playbook:object|required=playbook|closed=true|strict=false",
		"mcp__hunter__create_whiterabbit_template|object|template:object|required=template|closed=true|strict=false",
		"mcp__hunter__edit_ansible_playbook|object|changes:object,expected_lock_version:integer,id:integer|required=changes,expected_lock_version,id|closed=true|strict=false",
		"mcp__hunter__edit_whiterabbit_template|object|changes:object,expected_lock_version:integer,id:integer|required=changes,expected_lock_version,id|closed=true|strict=false",
		"mcp__hunter__get_cve|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_endpoint|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_job|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_playbook|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_program|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_run_group|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_run|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_target|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_template|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__get_vulnerability|object|id:string|required=id|closed=true|strict=false",
		"mcp__hunter__list_cves|object|cwe:string,ecosystem:string,has_fix:string,language:string,limit:integer,min_severity:string,modified_after:string,package:string,page:integer,published_after:string,q:string,tag:string,vendor:string|required=|closed=true|strict=false",
		"mcp__hunter__list_endpoints|object|content_type:string,has_query:string,limit:integer,methods:string,page:integer,path:string,q:string,status:string|required=|closed=true|strict=false",
		"mcp__hunter__list_jobs|object|limit:integer,page:integer,status:string|required=|closed=true|strict=false",
		"mcp__hunter__list_playbooks|object|limit:integer,page:integer|required=|closed=true|strict=false",
		"mcp__hunter__list_programs|object|bounty:string,bounty_max_gte:string,bounty_min_gte:string,collaboration:string,dir:string,favorites_only:string,limit:integer,page:integer,platforms:string,q:string,reports_24h_gte:string,reports_7d_gte:string,reports_gte:string,reports_month_gte:string,response_lte:string,scope_count_gte:string,scope_count_lte:string,scope_types:string,sort:string,status:string,trash_only:string|required=|closed=true|strict=false",
		"mcp__hunter__list_run_events|object|after_counter:integer,limit:integer,page:integer,run_id:integer|required=|closed=true|strict=false",
		"mcp__hunter__list_run_groups|object|limit:integer,page:integer|required=|closed=true|strict=false",
		"mcp__hunter__list_targets|object|limit:integer,page:integer,program:string,q:string,status:string|required=|closed=true|strict=false",
		"mcp__hunter__list_templates|object|kind:string,limit:integer,page:integer|required=|closed=true|strict=false",
		"mcp__hunter__list_vulnerabilities|object|limit:integer,page:integer,program:string,q:string,severity:string,status:string,tool:string|required=|closed=true|strict=false",
	}
	if !slices.Equal(gotContracts, wantContracts) {
		t.Fatalf("deferred Hunter tool schema categories drifted\n got: %v\nwant: %v", gotContracts, wantContracts)
	}

	forbiddenPrefixes := []string{
		"shell", "exec", "unified_exec", "patch", "file", "filesystem",
		"web", "browser", "computer", "app", "plugin", "skill", "image",
		"multi_agent", "spawn_agent", "send_message", "wait_agent", "request_permission",
	}
	forbiddenNames := []string{
		"shell_command", "exec_command", "write_stdin", "web_search",
		"computer", "image_generation", "request_permissions",
	}
	for _, name := range gotHunterNames {
		leaf := strings.TrimPrefix(name, "mcp__hunter__")
		for _, prefix := range forbiddenPrefixes {
			if strings.HasPrefix(leaf, prefix) {
				t.Fatalf("prohibited tool family %q is model-visible as %q", prefix, name)
			}
		}
		if slices.Contains(forbiddenNames, leaf) {
			t.Fatalf("prohibited tool %q is model-visible", name)
		}
	}
}

func TestRealCodexApplyPatchCannotMutateReadOnlyWorkspace(t *testing.T) {
	codexBin := exactPinnedCodex(t)

	providerRequests := make(chan map[string]any, 2)
	var providerCalls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/responses" {
			http.NotFound(w, r)
			return
		}
		var body map[string]any
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20))
		if err := decoder.Decode(&body); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		call := providerCalls.Add(1)
		if call > 2 {
			http.Error(w, "unexpected retry", http.StatusConflict)
			return
		}
		providerRequests <- body
		w.Header().Set("Content-Type", "text/event-stream")
		if call == 1 {
			_, _ = fmt.Fprint(w, applyPatchContractSSE())
			return
		}
		_, _ = fmt.Fprint(w, finalContractSSE())
	}))
	t.Cleanup(provider.Close)

	workingDir := t.TempDir()
	inv := buildInvocation(Config{
		CodexHome:  t.TempDir(),
		WorkingDir: workingDir,
	}, Request{Prompt: "Attempt the requested patch, then report the result."})
	providerConfig := []string{
		"--config", `model="gpt-5.4"`,
		"--config", `model_provider="hunter_contract"`,
		"--config", "model_providers.hunter_contract.name=" + tomlString("Hunter contract provider"),
		"--config", "model_providers.hunter_contract.base_url=" + tomlString(provider.URL+"/v1"),
		"--config", `model_providers.hunter_contract.wire_api="responses"`,
		"--config", "model_providers.hunter_contract.requires_openai_auth=false",
		"--config", "model_providers.hunter_contract.request_max_retries=0",
		"--config", "model_providers.hunter_contract.stream_max_retries=0",
		"--config", "model_providers.hunter_contract.supports_websockets=false",
	}
	args := append([]string{}, inv.Args[:len(inv.Args)-1]...)
	args = append(args, providerConfig...)
	args = append(args, inv.Args[len(inv.Args)-1])

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, codexBin, args...)
	cmd.Env = inv.Env
	cmd.Dir = workingDir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("real %s patch-denial invocation failed: %v\nstdout:\n%s\nstderr:\n%s", pinnedCodexVersion, err, stdout.String(), stderr.String())
	}
	if got := providerCalls.Load(); got != 2 {
		t.Fatalf("real Codex made %d provider requests, want 2", got)
	}
	<-providerRequests
	secondRequest := <-providerRequests
	assertFailedCustomToolOutput(t, secondRequest, "forbidden-patch")

	forbiddenPath := filepath.Join(workingDir, "forbidden.txt")
	if _, err := os.Stat(forbiddenPath); err == nil {
		t.Fatalf("read-only Codex sandbox created %s", forbiddenPath)
	} else if !os.IsNotExist(err) {
		t.Fatalf("inspect forbidden patch target: %v", err)
	}
}

func exactPinnedCodex(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("codex")
	if err != nil {
		t.Skipf("%s is unavailable: %v", pinnedCodexVersion, err)
	}
	output, err := exec.Command(path, "--version").CombinedOutput()
	if err != nil || strings.TrimSpace(string(output)) != pinnedCodexVersion {
		t.Skipf("%s is unavailable (found %q)", pinnedCodexVersion, strings.TrimSpace(string(output)))
	}
	return path
}

func toolSearchContractSSE() string {
	events := []map[string]any{
		{"type": "response.created", "response": map[string]any{"id": "resp-search"}},
		{"type": "response.output_item.done", "item": map[string]any{
			"type": "tool_search_call", "call_id": "hunter-catalog", "execution": "client",
			"arguments": map[string]any{"query": "hunter", "limit": 24},
		}},
		completedResponseEvent("resp-search"),
	}
	return contractSSE(events)
}

func applyPatchContractSSE() string {
	events := []map[string]any{
		{"type": "response.created", "response": map[string]any{"id": "resp-patch"}},
		{"type": "response.output_item.done", "item": map[string]any{
			"type": "custom_tool_call", "name": "apply_patch", "call_id": "forbidden-patch",
			"input": "*** Begin Patch\n*** Add File: forbidden.txt\n+written\n*** End Patch",
		}},
		completedResponseEvent("resp-patch"),
	}
	return contractSSE(events)
}

func finalContractSSE() string {
	events := []map[string]any{
		{"type": "response.created", "response": map[string]any{"id": "resp-contract"}},
		{"type": "response.output_item.done", "item": map[string]any{
			"type": "message", "role": "assistant", "id": "msg-contract",
			"content": []map[string]string{{"type": "output_text", "text": "captured"}},
		}},
		completedResponseEvent("resp-contract"),
	}
	return contractSSE(events)
}

func completedResponseEvent(id string) map[string]any {
	return map[string]any{"type": "response.completed", "response": map[string]any{
		"id": id,
		"usage": map[string]any{
			"input_tokens": 0, "input_tokens_details": nil, "output_tokens": 0,
			"output_tokens_details": nil, "total_tokens": 0,
		},
	}}
}

func contractSSE(events []map[string]any) string {
	var stream strings.Builder
	for _, event := range events {
		payload, _ := json.Marshal(event)
		fmt.Fprintf(&stream, "event: %s\ndata: %s\n\n", event["type"], payload)
	}
	return stream.String()
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func fakeReviewedMCPTools() []map[string]any {
	fixtures := []contractToolFixture{
		{name: "list_targets", properties: map[string]string{"limit": "integer", "page": "integer", "program": "string", "q": "string", "status": "string"}},
		{name: "get_target", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_cves", properties: map[string]string{"cwe": "string", "ecosystem": "string", "has_fix": "string", "language": "string", "limit": "integer", "min_severity": "string", "modified_after": "string", "package": "string", "page": "integer", "published_after": "string", "q": "string", "tag": "string", "vendor": "string"}},
		{name: "get_cve", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_vulnerabilities", properties: map[string]string{"limit": "integer", "page": "integer", "program": "string", "q": "string", "severity": "string", "status": "string", "tool": "string"}},
		{name: "get_vulnerability", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_endpoints", properties: map[string]string{"content_type": "string", "has_query": "string", "limit": "integer", "methods": "string", "page": "integer", "path": "string", "q": "string", "status": "string"}},
		{name: "get_endpoint", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_programs", properties: map[string]string{"bounty": "string", "bounty_max_gte": "string", "bounty_min_gte": "string", "collaboration": "string", "dir": "string", "favorites_only": "string", "limit": "integer", "page": "integer", "platforms": "string", "q": "string", "reports_24h_gte": "string", "reports_7d_gte": "string", "reports_gte": "string", "reports_month_gte": "string", "response_lte": "string", "scope_count_gte": "string", "scope_count_lte": "string", "scope_types": "string", "sort": "string", "status": "string", "trash_only": "string"}},
		{name: "get_program", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_templates", properties: map[string]string{"kind": "string", "limit": "integer", "page": "integer"}},
		{name: "get_template", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_jobs", properties: map[string]string{"limit": "integer", "page": "integer", "status": "string"}},
		{name: "get_job", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_playbooks", properties: map[string]string{"limit": "integer", "page": "integer"}},
		{name: "get_playbook", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_run_groups", properties: map[string]string{"limit": "integer", "page": "integer"}},
		{name: "get_run_group", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "get_run", properties: map[string]string{"id": "string"}, required: []string{"id"}},
		{name: "list_run_events", properties: map[string]string{"after_counter": "integer", "limit": "integer", "page": "integer", "run_id": "integer"}},
		{name: "create_whiterabbit_template", properties: map[string]string{"template": "object"}, required: []string{"template"}},
		{name: "create_ansible_playbook", properties: map[string]string{"playbook": "object"}, required: []string{"playbook"}},
		{name: "edit_whiterabbit_template", properties: map[string]string{"changes": "object", "expected_lock_version": "integer", "id": "integer"}, required: []string{"id", "expected_lock_version", "changes"}},
		{name: "edit_ansible_playbook", properties: map[string]string{"changes": "object", "expected_lock_version": "integer", "id": "integer"}, required: []string{"id", "expected_lock_version", "changes"}},
	}

	tools := make([]map[string]any, 0, len(fixtures))
	for _, fixture := range fixtures {
		properties := make(map[string]any, len(fixture.properties))
		for name, schemaType := range fixture.properties {
			properties[name] = map[string]any{"type": schemaType}
		}
		inputSchema := map[string]any{
			"type":                 "object",
			"properties":           properties,
			"additionalProperties": false,
		}
		if len(fixture.required) > 0 {
			inputSchema["required"] = fixture.required
		}
		tools = append(tools, map[string]any{
			"name": fixture.name, "description": "Reviewed Hunter tool " + fixture.name + ".",
			"inputSchema": inputSchema,
		})
	}
	return tools
}

func topLevelToolContracts(t *testing.T, request map[string]any) ([]string, []string) {
	t.Helper()
	tools, ok := request["tools"].([]any)
	if !ok {
		t.Fatalf("provider request has no top-level tools array: %#v", request["tools"])
	}
	contracts := make([]string, 0, len(tools))
	names := make([]string, 0, len(tools))
	for _, raw := range tools {
		tool, ok := raw.(map[string]any)
		if !ok {
			t.Fatalf("unexpected top-level tool: %#v", raw)
		}
		name, _ := tool["name"].(string)
		if name == "" && tool["type"] == "tool_search" {
			name = "tool_search"
		}
		if name == "" {
			t.Fatalf("top-level tool has invalid name: %#v", tool)
		}
		names = append(names, name)
		shape, err := json.Marshal(contractShape(tool))
		if err != nil {
			t.Fatalf("serialize %s contract shape: %v", name, err)
		}
		contracts = append(contracts, string(shape))
	}
	sort.Strings(contracts)
	sort.Strings(names)
	return contracts, names
}

func contractShape(value any) any {
	return contractShapeWithin(value, "")
}

func contractShapeWithin(value any, parent string) any {
	switch value := value.(type) {
	case map[string]any:
		shape := make(map[string]any, len(value))
		for key, child := range value {
			if key == "description" && parent != "properties" {
				continue
			}
			if key == "definition" {
				digest := sha256.Sum256([]byte(fmt.Sprint(child)))
				shape["definition_sha256"] = fmt.Sprintf("%x", digest)
				continue
			}
			shape[key] = contractShapeWithin(child, key)
		}
		return shape
	case []any:
		shape := make([]any, 0, len(value))
		for _, child := range value {
			shape = append(shape, contractShapeWithin(child, parent))
		}
		return shape
	default:
		return value
	}
}

func assertOnlyHunterToolSource(t *testing.T, request map[string]any) {
	t.Helper()
	tools, ok := request["tools"].([]any)
	if !ok {
		t.Fatalf("provider request has no tools array: %#v", request["tools"])
	}
	for _, raw := range tools {
		tool, ok := raw.(map[string]any)
		if !ok || (tool["name"] != "tool_search" && tool["type"] != "tool_search") {
			continue
		}
		description, _ := tool["description"].(string)
		const start = "You have access to tools from the following sources:\n"
		const end = "\nSome of the tools may not have been provided to you upfront"
		before, sources, found := strings.Cut(description, start)
		if !found || before == "" {
			t.Fatalf("tool_search has no closed source disclosure: %q", description)
		}
		sources, _, found = strings.Cut(sources, end)
		if !found || strings.TrimSpace(sources) != "- hunter" {
			t.Fatalf("tool_search sources drifted: %q", sources)
		}
		return
	}
	t.Fatal("provider request has no tool_search contract")
}

func findToolSearchOutput(t *testing.T, request map[string]any, callID string) map[string]any {
	t.Helper()
	input, ok := request["input"].([]any)
	if !ok {
		t.Fatalf("provider follow-up has no input array: %#v", request["input"])
	}
	var found map[string]any
	for _, raw := range input {
		item, ok := raw.(map[string]any)
		if !ok || item["type"] != "tool_search_output" || item["call_id"] != callID {
			continue
		}
		if found != nil {
			t.Fatalf("provider follow-up duplicated tool_search_output %q", callID)
		}
		found = item
	}
	if found == nil {
		t.Fatalf("provider follow-up omitted tool_search_output %q: %#v", callID, input)
	}
	return found
}

func assertFailedCustomToolOutput(t *testing.T, request map[string]any, callID string) {
	t.Helper()
	input, ok := request["input"].([]any)
	if !ok {
		t.Fatalf("provider follow-up has no input array: %#v", request["input"])
	}
	for _, raw := range input {
		item, ok := raw.(map[string]any)
		if !ok || item["type"] != "custom_tool_call_output" || item["call_id"] != callID {
			continue
		}
		output, err := json.Marshal(item["output"])
		if err != nil || len(output) == 0 || bytes.Equal(output, []byte("null")) {
			t.Fatalf("custom tool output %q has no result: %#v", callID, item)
		}
		if bytes.Contains(bytes.ToLower(output), []byte("success")) {
			t.Fatalf("read-only custom tool output reported success: %s", output)
		}
		return
	}
	t.Fatalf("provider follow-up omitted custom_tool_call_output %q: %#v", callID, input)
}

func outboundToolContracts(t *testing.T, request map[string]any) ([]string, []string) {
	t.Helper()
	tools, ok := request["tools"].([]any)
	if !ok {
		t.Fatalf("provider request has no top-level tools array: %#v", request["tools"])
	}
	if len(tools) != 1 {
		t.Fatalf("want one Hunter namespace and no built-in tools, got %d top-level tools: %#v", len(tools), tools)
	}
	namespace, ok := tools[0].(map[string]any)
	if !ok || namespace["type"] != "namespace" || namespace["name"] != "mcp__hunter" {
		t.Fatalf("unexpected model-visible namespace: %#v", tools[0])
	}
	children, ok := namespace["tools"].([]any)
	if !ok {
		t.Fatalf("Hunter namespace has no child tools: %#v", namespace)
	}

	contracts := make([]string, 0, len(children))
	names := make([]string, 0, len(children))
	for _, raw := range children {
		tool, ok := raw.(map[string]any)
		if !ok || tool["type"] != "function" {
			t.Fatalf("unexpected Hunter child tool: %#v", raw)
		}
		leaf, ok := tool["name"].(string)
		if !ok || leaf == "" {
			t.Fatalf("Hunter child has invalid name: %#v", tool)
		}
		name := "mcp__hunter__" + leaf
		names = append(names, name)

		schema, ok := tool["parameters"].(map[string]any)
		if !ok {
			t.Fatalf("%s has no object parameters schema: %#v", name, tool["parameters"])
		}
		properties, ok := schema["properties"].(map[string]any)
		if !ok {
			t.Fatalf("%s has no properties object: %#v", name, schema)
		}
		propertyCategories := make([]string, 0, len(properties))
		for propertyName, rawProperty := range properties {
			property, ok := rawProperty.(map[string]any)
			if !ok {
				t.Fatalf("%s.%s has invalid schema: %#v", name, propertyName, rawProperty)
			}
			propertyType, ok := property["type"].(string)
			if !ok {
				t.Fatalf("%s.%s has no literal type: %#v", name, propertyName, rawProperty)
			}
			propertyCategories = append(propertyCategories, propertyName+":"+propertyType)
		}
		sort.Strings(propertyCategories)
		required := make([]string, 0)
		if rawRequired, exists := schema["required"]; exists {
			for _, value := range rawRequired.([]any) {
				required = append(required, value.(string))
			}
		}
		sort.Strings(required)
		additionalProperties, ok := schema["additionalProperties"].(bool)
		if !ok {
			t.Fatalf("%s has no literal additionalProperties flag: %#v", name, schema)
		}
		contracts = append(contracts, fmt.Sprintf("%s|%v|%s|required=%s|closed=%v|strict=%v",
			name, schema["type"], strings.Join(propertyCategories, ","), strings.Join(required, ","),
			!additionalProperties, tool["strict"]))
	}
	sort.Strings(contracts)
	sort.Strings(names)
	return contracts, names
}
