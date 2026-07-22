# Hunter Sitemap — Root Exclusion and Dork Search Design

**Date:** 2026-07-21
**Status:** Approved in conversation; awaiting written-spec review.

## Goal

Improve the Sitemap department in two related ways:

1. A discovered root endpoint (`path == "/"`) does not count toward the
   default minimum of one endpoint and is not rendered in the tree by default.
   Users can explicitly opt it back in with an **Include `/` root** filter or
   select root endpoints with the `root:yes` dork.
2. Replace the host-only `q` search with the same robust search grammar used by
   the Programs, Vulnerabilities, and Targets departments: free text mixed with
   typed dorks, quoted values, wildcards, comparisons, `AND`/`OR`, and grouped
   expressions.

This remains a read-only web feature over the existing `sitemap_targets` and
`sitemap_endpoints` PostgreSQL tables. There are no schema or API changes.

## Existing Cause

`Sitemap::OriginsController` currently sends every active endpoint through
`Sitemap::EndpointFilter` for both grouped origin counts and lazy tree builds.
The filter has no default root exclusion. Consequently, an origin whose only
endpoint is `/` gets a count of one, passes the default `min_count=1`, and
renders `/` in its tree.

The current `q` parameter is applied separately as `host ILIKE` on the target
scope. It cannot search endpoint fields or parse the dork syntax available in
the other departments.

## Decisions

### Root endpoint behavior

- An endpoint is a root endpoint only when its normalized `path` is exactly
  `/`. Paths such as `//`, `/index`, and `/?a=1` (whose stored path is `/`) are
  governed by that exact normalized path rule.
- `Sitemap::EndpointFilter` excludes `path == "/"` by default, before applying
  other endpoint criteria. Because the same relation feeds counts and trees,
  the origin badge and displayed nodes remain consistent.
- A visible **Include `/` root** checkbox disables the default exclusion. It
  does not otherwise constrain the result: root endpoints still must satisfy
  every active method, status, path, content-type, query, and search condition.
- The checkbox state is forwarded to each lazy origin-tree request.
- `root:yes` is an actual dork predicate matching only `path == "/"`. The
  presence of a positive root term also disables the default root exclusion,
  allowing expressions such as `root:yes OR path:/api` to return both branches.
- `root:no` matches only non-root endpoints and does not disable the default.
- `path:/` keeps the normal case-insensitive substring semantics for `path`; it
  is not a special root opt-in. Root selection is deliberately explicit through
  the checkbox or `root:yes`.
- An explicit `min_count=0` may still show an origin with a zero badge and an
  empty tree. It does not implicitly re-enable the root endpoint.

### Search syntax

Add a sitemap-specific `Sitemap::SearchParser`, following the established
parser grammar rather than coupling this PostgreSQL module to a Mongo-backed
department:

```text
expression := or_expression
or         := and_expression (OR and_expression)*
and        := primary (AND? primary)*
primary    := '(' expression ')' | term
term       := KEY ':' [>=|<=|>|<] (QUOTED_VALUE | BARE_VALUE)
```

- Operators are case-insensitive; `&&` and `||` are aliases for `AND` and
  `OR`.
- Adjacent dork terms imply `AND`; `AND` binds tighter than `OR`.
- Parentheses group expressions.
- Quoted values may contain spaces.
- Unknown keys and ordinary words remain free text. Orphan `and`/`or` words
  also remain free text, so `cats or dogs` behaves as a phrase rather than a
  broken expression.
- A literal `*` in a dork value is the only wildcard. All other SQL wildcard
  characters are escaped.
- Malformed or invalid typed values never generate unsafe SQL or a 500. A
  recognized dork with an invalid boolean, number, or date is an always-false
  predicate, preventing an invalid filter from silently broadening results.

The supported keys and semantics are:

| Group | Keys | Behavior |
| --- | --- | --- |
| Text | `host`, `origin`, `program`, `path`, `url`, `content_type` | Case-insensitive substring; `*` enables anchored wildcard matching |
| Exact category | `method`, `scheme` | Case-insensitive exact match; `*` enables wildcard matching |
| Numeric | `port`, `status`, `length` | Exact integer or `>`, `>=`, `<`, `<=` comparison |
| Boolean | `has_query`, `root` | `yes`/`true`/`1`/`on` and `no`/`false`/`0`/`off` |
| Date/time | `seen` | Exact UTC calendar day or `>`, `>=`, `<`, `<=` comparison against `sitemap_endpoints.last_seen_at` |

Date-only comparisons use UTC day boundaries: exact means from the day's start
through (but not including) the next day; `>=` starts at the named day; `>`
starts at the next day; `<` stops before the named day; and `<=` stops before
the next day. Numeric values are parsed strictly as base-10 integers.

Plain free text matches, case-insensitively, across target `host`, `origin`, and
`program`, plus endpoint `path`, `url`, and `content_type`.

Examples:

```text
admin
host:*.example.com path:/api
method:POST AND status:>=400
(method:GET OR method:POST) AND has_query:yes
root:yes OR path:/health
seen:>=2026-07-01 length:>1024
```

## Components

### `Sitemap::SearchParser`

Create `web/app/services/sitemap/search_parser.rb`.

`Sitemap::SearchParser.call(query)` returns a value with:

- `free_text` — ordinary text left after recognized dork terms are removed.
- `expression` — a `Sitemap::DorkExpression::Term`, `And`, or `Or` tree, or
  `nil`.

The parser owns the supported-key allowlist and mirrors the behavior already
tested in the other departments.

### `Sitemap::DorkExpression`

Create `web/app/services/sitemap/dork_expression.rb`.

The expression nodes produce composable Arel predicates over
`Sitemap::Endpoint` joined to `Sitemap::Target`. The mapper is the only place
that translates public dork keys to database columns. Text is quoted/escaped by
Active Record/Arel; no user value is interpolated into SQL.

Expression nodes also expose whether they contain a positive `root:yes` term.
`EndpointFilter` uses that metadata solely to decide whether to apply the
default root exclusion; the `root:yes` term still contributes its normal exact
root predicate to the expression.

### `Sitemap::EndpointFilter`

Extend the existing service rather than introducing a competing query path:

```ruby
Sitemap::EndpointFilter.apply(
  scope,
  params,
  free_text: parsed.free_text,
  expression: parsed.expression,
  include_root: include_root?
)
```

The returned `ActiveRecord::Relation` applies, in order:

1. the default exact-root exclusion unless the checkbox is truthy or the dork
   expression contains `root:yes`;
2. existing method, status-family, path, has-query, and content-type filters;
3. the broad free-text predicate;
4. the typed dork expression.

All criteria compose with `AND`; internal `AND`/`OR` grouping in the dork AST is
preserved.

### `Sitemap::OriginsController`

Both `index` and `tree` parse `params[:q]` and pass the result to the same
endpoint-filter call.

For `index`:

1. Build the active target candidates, retaining the existing Program and
   Scheme sidebar filters.
2. Build one active endpoint relation joined to targets, constrain it to the
   candidate target IDs, and apply the endpoint filters plus parsed search.
3. Group that relation by `target_id` for the displayed counts.
4. Apply `min_count` as today. When `q` is present, also require a target to
   occur in the grouped relation so `min_count=0` does not make unrelated
   search results appear.

For `tree`, apply the identical endpoint and search criteria to the active
target's endpoint relation before calling `Sitemap::Tree.build`.

The query string forwarded by `_origin.html.erb` contains `q`, all endpoint
filter parameters, and `include_root`. Target-only Program/Scheme and display
threshold `min_count` remain index-only because the target has already been
selected.

### Search and filter UI

Replace the simple host-only box with the established Hunter search treatment:

- Placeholder explains free text and gives a short dork example.
- A Search button submits explicitly.
- A keyboard-accessible question-mark control opens a compact cheatsheet with
  Text, Category, Numeric/Date, Boolean, and Combine examples.
- The search form carries active sidebar filters in hidden inputs, so searching
  does not clear the filter panel.
- The existing filter form continues carrying `q`, and gains the
  **Include `/` root** checkbox.
- The root checkbox is unchecked by default and echoed when active.

No new Stimulus controller is required; the help panel follows the existing
CSS hover/focus-within implementation.

## Data Flow

```text
q -> SearchParser -> free text + dork AST
                         |
sidebar endpoint filters + root opt-in
                         |
                  EndpointFilter
                    /         \
          grouped origin     per-origin endpoint
              counts          relation -> Tree
```

The single `EndpointFilter` boundary is intentional: it prevents a root or
search rule from being applied to the badge but omitted from the lazy tree, or
vice versa.

## Error and Empty-State Behavior

- Invalid search input returns an empty or safely narrowed result, never raw
  SQL errors or a server error.
- A missing or removed target on the tree route remains `404`.
- An origin with no matching endpoints renders the existing tree empty state.
- A search with no matching origins renders the existing origin-list empty
  state.
- Existing Mongo sync behavior is untouched.

## Testing

### Parser tests

- Plain text, one dork, mixed free text and dorks.
- Adjacent/explicit `AND`, `OR` precedence, parentheses, quoted values,
  comparison operators, aliases, and unknown keys.
- Positive-root detection through nested expressions.

### Dork predicate tests

- Every key maps to the intended joined PostgreSQL column.
- Text substring and `*` wildcard behavior, including literal `%` and `_`.
- Exact categories are case-insensitive.
- Numeric/date comparisons and both boolean polarities.
- Invalid typed values produce no matches without raising.
- Nested `AND`/`OR` expressions preserve precedence.

### Endpoint filter tests

- `/` is excluded by default while non-root endpoints remain.
- The root checkbox includes `/` without removing non-root endpoints.
- `root:yes` opts in and selects root; `root:no` selects non-root.
- Root behavior composes with the existing sidebar filters, free text, and
  dork expressions.

### Integration/view tests

- A root-only origin is absent at the default `min_count=1`.
- `/` does not increment the default count or render in the default tree.
- The checkbox and `root:yes` each make the correct origin/count/tree visible.
- Free text and representative target/endpoint dorks filter counts and tree
  nodes identically.
- `q` and `include_root` are forwarded into lazy tree frame URLs.
- Search submissions preserve active filter values; filter submissions preserve
  `q`.
- The syntax-help UI lists the supported keys and combination grammar.

## Files

- Create `web/app/services/sitemap/search_parser.rb`.
- Create `web/app/services/sitemap/dork_expression.rb`.
- Modify `web/app/services/sitemap/endpoint_filter.rb`.
- Modify `web/app/controllers/sitemap/origins_controller.rb`.
- Modify `web/app/views/sitemap/origins/index.html.erb`.
- Modify `web/app/views/sitemap/origins/_filters.html.erb`.
- Modify `web/app/views/sitemap/origins/_origin.html.erb` only if its locals need
  separation between index and tree parameters.
- Add or extend focused service and integration tests under
  `web/test/services/sitemap/` and `web/test/integration/sitemap/`.

## Non-goals

- No schema/index migration in this change.
- No JSON API changes.
- No Mongo query or synchronization changes.
- No negation operator beyond boolean `no` values.
- No saved searches, autocomplete, query history, or client-side filtering.
