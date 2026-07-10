# Vulnerability page — robust filtering (ported from scope-ui)

**Date:** 2026-07-08
**Module:** vulnerability management (`web/app/.../vulnerabilities`)
**Status:** design approved, pending implementation plan

## Goal

Port scope-ui's robust filtering system to the Hunter vulnerabilities page,
adapted to the vulnerability MongoDB JSON format. Today the page has only a
free-text search plus two fixed dropdowns (severity, status). We want the full
scope experience: a **dork query language** in the search bar, a **faceted
sidebar** (multi-select checkboxes, program facet, date range), **active-filter
chips**, and a **sort control** — all Mongo-backed with an in-memory fallback.

Reference implementation lives in `tmp/scope/web/app/services/programs/`
(`search_parser.rb`, `dork_expression.rb`, `query.rb`, `filter.rb`) and the
`programs/` views. This spec adapts that structure; it does not invent a new one.

## Decisions (locked with the user)

- **Full system**, not a subset: dork language + faceted sidebar + chips + sort.
- **Faithful port of scope's service structure**, remapped to vuln fields —
  chosen over a fresh vuln-only filter (loses the AST) or a shared
  module-agnostic framework (YAGNI; generalize later if a third module needs it).
- **Sidebar facets:** Severity, Status, Tool, Type, Program (all multi-select
  with counts) and a Date range on `metadata.date`.
- **Facet counts use "all-other-filters" semantics** — each facet dimension's
  counts are computed with every *other* active filter applied but not its own,
  so selecting `critical` still shows how many `high` findings exist. One
  `$facet` aggregation.
- **The JSON API stays unchanged** for now (`Api::V1::VulnerabilitiesController`
  keeps using `MongoSource.all`). This work is the HTML page only.
- **Everything filterable via the dork bar** regardless of what has sidebar UI.

## Architecture

New services under `web/app/services/vulnerabilities/`, mirroring scope:

| Service | Responsibility |
|---|---|
| `SearchParser` | Parse the search bar into `free_text` + a `DorkExpression` AST. Recursive descent; same grammar as scope. Only the `KEYS` whitelist changes. |
| `DorkExpression` | AST nodes `Term`/`And`/`Or` + a `Mapper` that is the single source of truth for per-key semantics, with `to_mongo` and `evaluate` side by side. Remapped to vuln fields. |
| `Query` | Page orchestrator: builds the Mongo match doc from facet params + the dork AST, runs count + a `$facet` aggregation for sidebar counts + the paged window; falls back to the in-memory `Filter` when Mongo is empty/unreachable. Returns a `Result` struct. |
| `Filter` | In-memory equivalent of the match doc, used for the fallback path and as a unit-test seam. Uses `DorkExpression#evaluate`. |
| `Sort` | Sort keys → Mongo sort spec, incl. a severity rank (critical→info) and a stable tiebreaker. |

`MongoSource` stays the raw collection/CRUD + index layer; `Query` uses
`MongoSource.collection` and the existing `HunterMongo.ensure_indexes_once!`
bootstrap. The `OverviewController#index` switches from `MongoSource.all` to
`Vulnerabilities::Query.call(filter_params)`.

### Data flow

```
params ─▶ OverviewController#index
           │  permit filter params
           ▼
        SearchParser.call(params[:q]) ─▶ { free_text, expression(AST) }
           │
           ▼
        Query.call(params + free_text + expression)
           │  mongo_usable? ── yes ─▶ match_doc ─▶ collection.count / $facet / find().sort().skip().limit()
           │                  no  ─▶ Filter.call(all) + Sort  (in-memory)
           ▼
        Result { findings, total, facets{severity,status,tool,type,program},
                 page, per_page, has_next, sort_key, sort_dir }
           │
           ▼
        views: _filters (search + sort), _facets sidebar, _active_chips,
               _findings_table, pagination
```

## Dork keys → vuln JSON mapping

The `Mapper` implements each key in **both** `to_mongo` and `evaluate` (kept
adjacent so a key cannot be added on one path without the other).

| dork key | field | match semantics |
|---|---|---|
| `severity` | `finding.severity` | exact (case-insensitive) |
| `status` | `report.status` | exact |
| `tool` | `metadata.tool` | exact |
| `type` | `finding.type` | exact |
| `program` | `metadata.program` | regex, i |
| `asset` | `metadata.asset` | regex, i |
| `name` | `finding.name` | regex, i |
| `cwe` | `finding.cwe` | exact |
| `tag` | `finding.tags[]` | array membership (exact element) |
| `host` | `target.host` | regex, i |
| `url` | `target.url` | regex, i |
| `ip` | `target.ip` | exact |
| `port` | `target.port` | exact |
| `method` | `target.method` | exact |
| `submitted` | `report.submitted` | bool (`true/yes/1` … `false/no/0`) |
| `confidence` | `poc.confidence` | exact |
| `date` | `metadata.date` | range (lexical date compare, default `>=`) |

`KEYS` whitelist = the keys above. Unknown `foo:bar` falls back to free text
(scope's behavior). Free-text (leftover words) searches `finding.name`,
`target.host`, `metadata.program`, `target.url` via case-insensitive regex `$or`.

**Note on matching semantics:** exact keys match case-insensitively on both
paths (anchored `^…$` regex with option `i` in Mongo, `String#casecmp?` in
Ruby) so `to_mongo` and `evaluate` stay in parity regardless of stored casing.
`date` is the only range key: `metadata.date` is stored as a string, and
lexical `$gte`/`$lte` compares ISO-8601 correctly, so no numeric cast is needed;
a missing/blank date never matches a range term. `port` is exact (its string
storage makes a numeric range unreliable without a schema change).

## UI

Rendered in the existing monochrome design language, inside
`overview/index.html.erb`. Layout becomes a two-column shell: facet sidebar +
main results column (search bar, chips, sort, table, pagination).

- **`overview/_filters`** — dork-aware search field (keeps the existing
  `filter_form` Stimulus controller for live submit) + sort `<select>`.
- **`overview/_facets`** (new) — sidebar. Severity / Status render from the
  fixed `SEVERITIES` / `STATUSES` vocab; Tool / Type / Program render from Mongo
  `distinct`. Each option shows its "all-other-filters" count. Date range is two
  `<input type="date">` (from/to) bound to `metadata.date`. Checkbox / range
  changes submit the form (multi-select via repeated `severity[]` params).
- **`overview/_active_chips`** (new) — one chip per active filter value with an
  individual remove link (re-links to the same page minus that value) plus a
  "Clear all" that resets to the base path.
- Findings table, pagination, and the detail drawer are unchanged.

Query/filter params permitted by the controller:
`q, sort, dir, page`, and array facets `severity[], status[], tool[], type[],
program[], date_from, date_to`.

## Testing

Follows Hunter conventions: Mongo is doubled (no live Mongo), `stub_methods`
helper, Minitest.

- **`SearchParser` unit** — grammar (`AND`/`OR`/parens/precedence), range ops,
  quoted values, unknown-key demotion to free text, prose like "cats or dogs"
  not parsed as operators, empty input.
- **`DorkExpression::Mapper` unit** — for each key, assert `to_mongo` emits the
  expected clause **and** `evaluate` agrees against a `Vulnerability` PORO
  (parity is the invariant that keeps the two paths honest).
- **`Query` integration** — doubled collection: match-doc shape for combined
  facet + dork params, `$facet` count semantics (other-filters-but-not-self),
  pagination (`has_next`, offsets), and the in-memory fallback path when the
  collection is empty/unreachable.
- **`Sort` unit** — severity rank ordering + tiebreaker.
- **Controller / view** — `overview` renders facets with counts, active chips
  with working remove links, and applies a dork query end to end (stubbed
  `Query`).

## Out of scope

- JSON API changes (stays on `MongoSource.all`).
- Saved filters / shareable filter presets.
- Numeric range *sliders* (scope's dual-range UI) — vulns lack the numeric
  fields that motivated them; the date range is the only range control.
- Generalizing the filter into a shared cross-module framework.
