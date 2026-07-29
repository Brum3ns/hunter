# Assistant MCP LLM Brief Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the LLM how to use every read tool by enriching native MCP surfaces — a server-level `Instructions` brief, richer per-tool descriptions, and per-field input-schema descriptions carrying the dork grammar, filters, id formats, pagination, and read-only nature.

**Architecture:** Add a `Description` field to `readmodule.ListField` (emitted into the generated JSON schema); set `mcp.ServerOptions{Instructions: …}` in the hunter-mcp server; enrich each of the 20 read tools' `ListDesc`/`GetDesc` and list-field descriptions with concrete, code-derived content. Descriptions are advertised metadata only — they never affect closed-input decode or closed-output validation. All changes are Go-side in `assistant/mcp`; the existing catalog-golden snapshots them.

**Tech Stack:** Go 1.25 (`assistant/mcp`), the modelcontextprotocol go-sdk v1.6.0, `go test`.

## Global Constraints

- **Native surfaces only** (design §Architecture): server `Instructions` + per-tool `Description` + per-field schema `description`. No mounted `.md`/skills, no `--allowedTools` change, no lockdown change. Descriptions are advertised metadata; do NOT alter decode/validation, tool names, scopes, id patterns, or projections.
- **Scope:** the 20 domain read tools only. Do NOT touch the authoring tools (`get_selected_context`, `get_artifact_example`, `get_authoring_policy`, validation) or add write tools.
- **Accuracy is a Rails↔Go contract:** the dork keys below are copied verbatim from each Rails `SearchParser::KEYS`; filters from each machine controller `params.permit`/Go `ListFields`; id formats from each Go `IDPattern`; limits from `MAX_LIMIT`. Each enriched Go module gets a one-line comment citing its Rails `SearchParser` (or "no dork parser") as source of truth.
- Pagination: `list_*` returns `{correlation_id, count, page, limit, items[]}`; `page` 1-based; `limit` default & max **50**, except `list_run_events` max **100**. `count` is the total match count.
- Go: `cd assistant/mcp && go test ./... && go vet ./... && gofmt -l .`. Commit author `Claude <noreply@anthropic.com>`, one-sentence messages.

### Reference tables (the code analysis — source for all description text)

**Dork keys** (verbatim from Rails `app/services/<m>/search_parser.rb` `KEYS`):
- `targets` (`q` on `list_targets`): `host url ip port method scheme path title webserver content_type tech status program tool page_type`
- `vulnerabilities` (`q` on `list_vulnerabilities`): `severity status tool type program asset name cwe tag host url ip port method submitted confidence date`
- `sitemap` (`q` on `list_endpoints`): `host origin program path url content_type method scheme port status length has_query root seen`
- `programs` (`q` on `list_programs`): `asset program name slug org organization tag lang language platform mode bounty vdp active hof hall_of_fame reports reports_24h reports_7d reports_30d reports_month scope avg avg_reward max max_reward min min_reward response`
- `cves`: **NO dork parser.** `q` on `list_cves` is a plain case-insensitive substring search over id/summary/details.
- control-center tools: **no `q`/dork.**

**Per-tool filters (Go `ListFields`) + id format:**
| Tool pair | list filters (besides page/limit) | `q`? | get id format |
|---|---|---|---|
| `list_targets`/`get_target` | `program`, `status` | dork | SafeID (alive-target id) |
| `list_cves`/`get_cve` | `ecosystem`, `package`, `language`, `vendor`, `cwe`, `tag`, `has_fix`, `min_severity`, `published_after`, `modified_after` | substring | `CVE-2024-1234` / `GHSA-…` |
| `list_vulnerabilities`/`get_vulnerability` | `program`, `severity`, `status`, `tool` | dork | Mongo ObjectId hex |
| `list_endpoints`/`get_endpoint` | `path`, `has_query`, `content_type`, `methods`, `status` | dork | positive integer |
| `list_programs`/`get_program` | `status`, `bounty`, `collaboration`, `scope_count_gte`, `scope_count_lte`, `reports_gte`, `platforms`, `scope_types`, `sort`, `dir` | dork | program `sid` |
| `list_templates`/`get_template` | `kind` | no | positive integer |
| `list_jobs`/`get_job` | `status` | no | positive integer |
| `list_playbooks`/`get_playbook` | (none) | no | positive integer |
| `list_run_groups`/`get_run_group` | (none) | no | positive integer |
| `get_run` (get only) | — | — | positive integer |
| `list_run_events` (list only, max 100) | `run_id` (required), `after_counter` | no | — |

---

### Task 1: Add `Description` to `readmodule.ListField` and emit it in the schema

**Files:**
- Modify: `assistant/mcp/internal/readmodule/spec.go` (add field), `assistant/mcp/internal/readmodule/build.go` (`listSchema`)
- Test: `assistant/mcp/internal/readmodule/readmodule_test.go`

**Interfaces:**
- Produces: `readmodule.ListField` gains `Description string`. `listSchema` emits `"description": <f.Description>` on a field when non-empty, and fixed descriptions on `page`/`limit`. `Build`/`BuildList`/`BuildGet`, decode, and output validation are unchanged.

- [ ] **Step 1: Write the failing test** (add to `readmodule_test.go`)

```go
func TestListSchemaCarriesFieldDescriptions(t *testing.T) {
	s := spec()
	s.ListFields = []ListField{{Name: "q", Kind: "string", MaxLen: 200, Description: "Dork search. Keys: host,path."}}
	tl := find(t, Build(s), "list_things")
	var schema struct {
		Properties map[string]struct {
			Description string `json:"description"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(tl.InputSchema, &schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	if schema.Properties["q"].Description != "Dork search. Keys: host,path." {
		t.Fatalf("q description missing: %+v", schema.Properties["q"])
	}
	if schema.Properties["page"].Description == "" || schema.Properties["limit"].Description == "" {
		t.Fatalf("page/limit descriptions missing")
	}
}
```

(The test file already imports `encoding/json`; if not, add it. `spec()` and `find()` helpers exist from the earlier readmodule tests.)

- [ ] **Step 2: Run it to verify failure** — `cd assistant/mcp && go test ./internal/readmodule/ -run TestListSchemaCarriesFieldDescriptions` → FAIL (no description emitted).

- [ ] **Step 3: Add the field** in `spec.go` to the `ListField` struct:

```go
	// Description is the human/LLM-facing explanation emitted as this field's
	// JSON-schema "description" (advertised only; never affects decoding).
	Description string
```

- [ ] **Step 4: Emit it** in `build.go` `listSchema`. Give `page`/`limit` fixed descriptions, and set each field's description when non-empty. Replace the `page`/`limit` map literals and the field loop bodies so the built schema includes `description`:

```go
	props := map[string]any{
		"page":  map[string]any{"type": "integer", "minimum": 1, "maximum": 100000, "description": "1-based page number (default 1)."},
		"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": spec.maxItems(), "description": "Max items per page (default and max " + strconv.Itoa(spec.maxItems()) + ")."},
	}
	for _, f := range spec.ListFields {
		var m map[string]any
		if f.Kind == "int" {
			m = map[string]any{"type": "integer"}
			if f.Min != 0 || f.Max != 0 {
				m["minimum"], m["maximum"] = f.Min, f.Max
			}
		} else {
			m = map[string]any{"type": "string"}
			if f.MaxLen > 0 {
				m["maxLength"] = f.MaxLen
			}
		}
		if f.Description != "" {
			m["description"] = f.Description
		}
		props[f.Name] = m
	}
```

(Add `"strconv"` to `build.go` imports if not already present.)

- [ ] **Step 5: Run tests** — `cd assistant/mcp && go test ./internal/readmodule/ && gofmt -l internal/readmodule/ && go vet ./internal/readmodule/` → PASS/clean. (Existing readmodule tests still pass — the only change is added, optional schema keys.)

- [ ] **Step 6: Commit**

```bash
git add assistant/mcp/internal/readmodule/
git commit -m "Let readmodule list fields carry a description emitted into the tool input schema."
```

---

### Task 2: Set the server-level `Instructions` brief

**Files:**
- Modify: `assistant/mcp/cmd/hunter-mcp/main.go` (add the const; pass `Instructions` in `mcp.ServerOptions`)
- Test: `assistant/mcp/cmd/hunter-mcp/main_test.go` (create if absent) OR `assistant/mcp/internal/runner/…` — see note.

**Interfaces:**
- Produces: `mcp.NewServer(..., &mcp.ServerOptions{Capabilities: …, Instructions: hunterInstructions})`. `hunterInstructions` is a package const in `main`.

- [ ] **Step 1: Add the const** in `main.go`:

```go
const hunterInstructions = "Hunter Assistant read-only tools. These tools ONLY read data; they never create, update, delete, run, or send anything.\n\n" +
	"Listing & counting: every list_* tool returns {correlation_id, count, page, limit, items[]}. `count` is the TOTAL number of matches — use it to answer \"how many\" without paging. Page with `page` (1-based) and `limit` (default and max 50; list_run_events max 100).\n\n" +
	"Detail: the read get_* tools each take an `id`. Formats differ: get_endpoint/get_template/get_job/get_playbook/get_run_group/get_run use a positive integer; get_cve uses a CVE id like \"CVE-2024-1234\" (GHSA ids also accepted); get_vulnerability uses a Mongo ObjectId hex string; get_program uses a program sid; get_target uses an alive-target id.\n\n" +
	"Search (the `q` field): where a tool accepts `q` it supports a dork grammar — bare words match free text; `key:value` filters a field; multiple terms AND together; quote values with spaces (\"...\"). There is no negation or wildcard operator; to exclude, use a boolean field's no/false value where one exists. Each tool's description and its `q` field description list that tool's dork keys. Examples: list_endpoints q=`path:/admin status:200`; list_programs q=`platform:hackerone bounty:yes`; list_vulnerabilities q=`severity:high status:open`. Note: list_cves `q` is a plain substring search over id/summary/details, not a dork.\n\n" +
	"Prefer one well-filtered call. Consult each tool's description and input-field descriptions before calling."
```

- [ ] **Step 2: Wire it** — in the `mcp.NewServer(...)` call, add `Instructions: hunterInstructions` to the `&mcp.ServerOptions{...}` literal (keep the existing `Capabilities`).

- [ ] **Step 3: Write the test.** The runner's catalog test builds a registry, not the SDK server, so test the const directly. Add `assistant/mcp/cmd/hunter-mcp/main_test.go` (package `main`):

```go
package main

import "testing"

func TestInstructionsStateReadOnlyAndDork(t *testing.T) {
	for _, want := range []string{"read", "only", "count", "page", "limit", "dork", "id"} {
		if !containsFold(hunterInstructions, want) {
			t.Fatalf("instructions missing %q", want)
		}
	}
}

func containsFold(s, sub string) bool {
	return len(sub) == 0 || (len(s) >= len(sub) && indexFold(s, sub) >= 0)
}
```

Simpler: import `strings` and assert `strings.Contains(strings.ToLower(hunterInstructions), want)` for each of: `"read", "only", "count", "page", "limit", "dork", "get_", "id"`. Use whichever compiles cleanly; the point is presence of the read-only statement, pagination/count, id, and the dork grammar.

- [ ] **Step 4: Run + build** — `cd assistant/mcp && go test ./cmd/hunter-mcp/ && go build ./... && go vet ./... && gofmt -l .` → PASS/clean.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/cmd/hunter-mcp/
git commit -m "Advertise a read-only usage brief via the hunter-mcp server instructions."
```

---

### Task 3: Enrich the four dork modules (targets, vulnerabilities, sitemap, programs)

**Files:** Modify `assistant/mcp/internal/modules/{targets/targets.go, vulnerabilities/module.go, sitemap/module.go, programs/module.go}`. Modify `assistant/mcp/internal/runner/testdata/catalog_golden.json` (regen). Test: add per-module description tests in each module's `*_test.go`.

**Interfaces:** Consumes `readmodule.ListField.Description` (Task 1). Produces enriched `ListDesc`/`GetDesc` + a `Description` on every `ListField` for these four modules.

For EACH module set the `q` field `Description` to `"Dork/free-text search. Keys: <comma-joined dork keys>. Syntax: bare words = free text; key:value filters; multiple terms AND; quote values with spaces (no negation/wildcard operators). Example: <example>."` using that module's keys from the reference table, and add a one-line `Description` to every other list field. Set `GetDesc` to name the id format. Add a comment `// Dork keys mirror Rails <M>::SearchParser::KEYS (source of truth).` above each `q` field.

Concrete values:

- **targets** (`targets.go`): q keys `host,url,ip,port,method,scheme,path,title,webserver,content_type,tech,status,program,tool,page_type`; example `status:200 tech:nginx`. `program` desc: `"Filter by bug-bounty program name."`; `status` desc: `"Filter by HTTP status code, e.g. 200."` `GetDesc`: `"Return the full record for one alive target by its id."`
- **vulnerabilities** (`module.go`): q keys `severity,status,tool,type,program,asset,name,cwe,tag,host,url,ip,port,method,submitted,confidence,date`; example `severity:high status:open`. `program`: `"Filter by program name."`; `severity`: `"Filter by finding severity (e.g. critical, high, medium, low)."`; `status`: `"Filter by report status (e.g. open, triaged, resolved)."`; `tool`: `"Filter by the tool that produced the finding."` `GetDesc`: `"Return the full record for one vulnerability by its Mongo ObjectId hex id."`
- **sitemap** (`module.go`): q keys `host,origin,program,path,url,content_type,method,scheme,port,status,length,has_query,root,seen`; example `path:/admin status:200`. `path`: `"Filter by URL path (substring)."`; `has_query`: `"Filter to endpoints whose URL has a query string (true/false)."`; `content_type`: `"Filter by response content type (substring)."`; `methods`: `"Comma-separated HTTP methods to include, e.g. GET,POST."`; `status`: `"Filter by HTTP status family: 2,3,4,5."` `GetDesc`: `"Return the full record for one sitemap endpoint by its integer id."`
- **programs** (`module.go`): q keys `asset,program,name,slug,org,organization,tag,lang,language,platform,mode,bounty,vdp,active,hof,hall_of_fame,reports,reports_24h,reports_7d,reports_30d,reports_month,scope,avg,avg_reward,max,max_reward,min,min_reward,response`; example `platform:hackerone bounty:yes`. `status`: `"Filter by program status: public or private."`; `bounty`: `"Filter by bounty presence: with or without."`; `collaboration`: `"Filter by collaboration: yes or no."`; `scope_count_gte`: `"Minimum in-scope asset count."`; `scope_count_lte`: `"Maximum in-scope asset count."`; `reports_gte`: `"Minimum resolved report count."`; `platforms`: `"Comma-separated platform slugs, e.g. hackerone,bugcrowd."`; `scope_types`: `"Comma-separated scope types, e.g. web,mobile."`; `sort`: `"Sort key (e.g. date, bounty_max, reports)."`; `dir`: `"Sort direction: asc or desc."` `GetDesc`: `"Return the full record for one program by its sid."`

Also enrich each `ListDesc` to end with `" Use q for dork search (see the q field for keys)."` where a dork `q` exists.

- [ ] **Step 1: Write per-module description tests** — in each module's `*_test.go`, add a test asserting the built `list_*` tool's `q` field description contains that module's key list marker (e.g. for sitemap, contains `"has_query"` and `"root"`; for programs, contains `"hall_of_fame"` and `"avg_reward"`; for vulnerabilities, contains `"confidence"`; for targets, contains `"page_type"` and `"webserver"`), and that `get_*`'s description is non-empty. Parse `InputSchema` JSON like Task 1's test.

- [ ] **Step 2: Run to verify failure** — `cd assistant/mcp && go test ./internal/modules/{targets,vulnerabilities,sitemap,programs}/` → FAIL.

- [ ] **Step 3: Apply the descriptions** to each module's `Spec` per the concrete values above.

- [ ] **Step 4: Run module tests** — same command → PASS. Then `go build ./...`.

- [ ] **Step 5: Regenerate the catalog golden** — run `go test ./internal/runner/ -run TestCatalogMatchesGolden`; it will fail on the changed descriptions/schemas for these four modules' tools. Update those entries in `testdata/catalog_golden.json` to the new advertised JSON (regenerate by capturing `registry.Tools()` output as in the F1 pattern, or hand-update the changed `description`/`input_schema` fields). Re-run until green. A change to any tool name/scope/output_schema here is a bug — only `description` and `input_schema.properties.*.description` may change.

- [ ] **Step 6: Commit**

```bash
git add assistant/mcp/internal/modules/targets/ assistant/mcp/internal/modules/vulnerabilities/ assistant/mcp/internal/modules/sitemap/ assistant/mcp/internal/modules/programs/ assistant/mcp/internal/runner/testdata/catalog_golden.json
git commit -m "Document dork keys and filters on the targets, vulnerabilities, sitemap, and programs MCP tools."
```

---

### Task 4: Enrich the non-dork modules (cves + control center)

**Files:** Modify `assistant/mcp/internal/modules/{cves/module.go, cc_templates/module.go, cc_jobs/module.go, cc_playbooks/module.go, cc_run_groups/module.go, cc_runs/module.go, cc_run_events/module.go}`. Modify `testdata/catalog_golden.json`. Test: per-module `*_test.go`.

**Interfaces:** Consumes `ListField.Description` (Task 1). Produces enriched descriptions for the seven non-dork tools.

Concrete values:

- **cves** (`module.go`): `q` desc: `"Plain case-insensitive substring search over CVE id, summary, and details. Not a dork — use the typed filters for precise matches."` Add a comment `// cves has no Rails SearchParser; q is a plain substring search.` Field descs: `ecosystem`: `"Package ecosystem, e.g. npm, PyPI, Go."`; `package`: `"Affected package name."`; `language`: `"Affected language."`; `vendor`: `"Affected vendor."`; `cwe`: `"CWE id, e.g. CWE-79."`; `tag`: `"Filter by tag."`; `has_fix`: `"true/false — whether a fix is available."`; `min_severity`: `"Minimum severity: critical, high, medium, or low."`; `published_after`: `"ISO-8601 date; only CVEs published on/after it."`; `modified_after`: `"ISO-8601 date; only CVEs modified on/after it."` `GetDesc`: `"Return the full record for one CVE by id (e.g. CVE-2024-1234; GHSA ids also accepted)."`
- **cc_templates**: `kind` desc: `"Filter by template kind: cmdscript or workflow."` `GetDesc`: `"Return the full record for one Control Center template by its integer id."`
- **cc_jobs**: `status` desc: `"Filter by job status: queued, running, succeeded, failed, or pending."` `GetDesc`: `"Return the full record for one Control Center job by its integer id (excludes internal targeting fields)."`
- **cc_playbooks**: no list fields — set `ListDesc`: `"List and count Control Center Ansible playbooks, ordered by name. Page with page/limit."`; `GetDesc`: `"Return the full record for one Ansible playbook by its integer id."`
- **cc_run_groups**: no list fields — `ListDesc`: `"List and count Control Center Ansible run groups, newest first. Page with page/limit."`; `GetDesc`: `"Return the full record for one run group by its integer id, including child run summaries. Never includes execution_payload."`
- **cc_runs** (get only): `GetDesc`: `"Return the full record for one Ansible run by its integer id (excludes secret snapshot fields: playbook_yaml, inventory_yaml, known_hosts, lease_digest, runner_id)."`
- **cc_run_events** (list only, max 100): `run_id` desc: `"Required. The integer run id whose events to list."`; `after_counter` desc: `"Cursor: return only events with counter greater than this (for paging through a run's event stream)."` `ListDesc`: `"List a run's Ansible events in counter order (max 100 per page). Requires run_id; use after_counter to page."`

- [ ] **Step 1: Write per-module tests** — assert `list_cves`'s `q` description contains `"substring"` and `"Not a dork"`; `cc_run_events`'s `run_id` description contains `"Required"`; each `get_*` description is non-empty and (for cc_runs) mentions the excluded fields. Parse `InputSchema` as before.

- [ ] **Step 2: Run to verify failure** — `cd assistant/mcp && go test ./internal/modules/{cves,cc_templates,cc_jobs,cc_playbooks,cc_run_groups,cc_runs,cc_run_events}/` → FAIL.

- [ ] **Step 3: Apply** the descriptions per the concrete values above.

- [ ] **Step 4: Run module tests** → PASS. Then `go build ./...`.

- [ ] **Step 5: Regenerate the catalog golden** for these seven modules' tools (same procedure as Task 3 Step 5). Only `description`/`input_schema.properties.*.description` may change.

- [ ] **Step 6: Commit**

```bash
git add assistant/mcp/internal/modules/cves/ assistant/mcp/internal/modules/cc_templates/ assistant/mcp/internal/modules/cc_jobs/ assistant/mcp/internal/modules/cc_playbooks/ assistant/mcp/internal/modules/cc_run_groups/ assistant/mcp/internal/modules/cc_runs/ assistant/mcp/internal/modules/cc_run_events/ assistant/mcp/internal/runner/testdata/catalog_golden.json
git commit -m "Document filters and id formats on the cves and Control Center MCP tools."
```

---

### Task 5: Full verification

- [ ] **Step 1: Go suite** — `cd assistant/mcp && go test -count=1 ./... && go vet ./... && gofmt -l .` → all pass; vet clean; `gofmt -l` empty. Confirm `TestCatalogMatchesGolden` and `TestAdversarialToolInputFixtures` pass (the adversarial dangerous names still map to `unknown_tool` — descriptions don't change tool names).
- [ ] **Step 2: Coverage self-check** — confirm, against the Global Constraints reference tables: every `list_*` with a dork has its full key list in the `q` description; every list field has a `description`; every `get_*` names its id format; the server `Instructions` states read-only + pagination + count + id-varies + dork grammar + examples. Record the check in the report.
- [ ] **Step 3: No commit** — verification only.

---

## Self-Review

**Spec coverage:** server `Instructions` → Task 2 ✓; per-tool descriptions → Tasks 3,4 ✓; per-field descriptions + builder change → Task 1 + Tasks 3,4 ✓; Rails↔Go contract (dork keys verbatim + source comment) → Tasks 3,4 ✓; the code-analysis extraction → embedded in Global Constraints reference tables ✓; golden + presence tests → Tasks 1–5 ✓; scope = 20 read tools only, no authoring tools, no lockdown change → Global Constraints ✓.

**Placeholder scan:** every field/tool description string is given verbatim; dork keys are the exact `KEYS` copied from the Rails parsers; the `Instructions` const is given in full. No "TBD"/"similar to". ✓

**Type consistency:** `ListField.Description` (Task 1) is used identically in Tasks 3,4. `hunterInstructions` const name consistent (Task 2). Golden-file edits restricted to `description`/`input_schema` in Tasks 3,4,5. ✓

**Note — Rails↔Go dork-key drift:** the keys are copied from Rails `SearchParser::KEYS` and are not machine-synced across languages; the source-of-truth comment + this plan's reference table are the guard. If a Rails parser's keys change later, the matching Go module description and this table must change together.
