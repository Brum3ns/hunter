# Hunter sitemap — design

**Date:** 2026-07-18
**Status:** Approved — ready for implementation plan.

## Goal

Give every target a **sitemap** — a Burp/Caido-style tree of the endpoints that
belong to it. Endpoints are sourced from two MongoDB collections (`katana`
crawl output and `wayback` archive URLs) and related, in PostgreSQL, to the
alive assets we already show on the Target page. The deliverable of *this* spec
is the **relation and its sync** (the durable, well-structured link between
Mongo-sourced endpoints and Mongo-sourced targets, materialized in Postgres);
the sitemap UI is a follow-on that consumes it.

## Background: where the data lives today

- **Targets** are *not* in Postgres. A `Target` is a PORO
  (`web/app/models/target.rb`) wrapping a document from the MongoDB `alive`
  collection (httpx probe output): one document per probed asset, carrying
  `target.host/port/scheme/url`, `metadata.program`, `metadata.date`, `tech[]`,
  `http.*`. Read via `Targets::MongoSource`.
- **Endpoints** live in two Mongo collections written by external tools:
  - `katana` — crawl output. Shape: `request.endpoint` (full URL),
    `request.method`, `response.status_code`, `response.content_length`,
    `response.body`, `timestamp`. **No program/host/target tag — just the URL.**
  - `wayback` — archived URLs (historical). A URL list; most docs carry little
    beyond the URL (and possibly a timestamp).
- **Postgres** today holds only users, sessions, API tokens, and config.
- **Mongo runs as a replica set** in both prod and (as of 2026-07-18) dev, so
  **change streams are available**.

The consequence that shapes everything below: the external tools write Mongo
directly — **Rails never sees those writes**. So Postgres cannot be a second
source of truth; it can only be a *derived projection* of Mongo.

## Core principle: Postgres is a one-way, rebuildable projection

Sync is strictly **Mongo → Postgres, one direction**. Mongo is authoritative.
Postgres holds a materialized read model shaped for the relational sitemap
(endpoint → target, tree queries, joins, tombstones) — the one thing Mongo is
awkward at here. If the projection ever drifts, the tables can be dropped and
rebuilt from Mongo.

This reframing is what makes deletes/updates tractable: it is a projection
problem (freshness + delete detection), not a distributed-transaction or
two-way-sync problem (which would need conflict resolution — deliberately
avoided).

**Rule:** never write authoritative asset/endpoint data to Postgres from the
app. App-owned data (future tags, notes, "reviewed" flags) must live in
*separate* columns/tables the sync never touches, so the projected columns
always remain Mongo's to own.

## Schema

Two thin tables. SQL types are indicative; final column list is settled here.

```
sitemap_targets               -- projection of the `alive` collection; 1:1 with an origin
  id             bigint  PK
  origin         text    NOT NULL UNIQUE   -- "https://www.example.com:443" (stable natural key)
  scheme         text    NOT NULL
  host           text    NOT NULL
  port           integer NOT NULL
  program        text
  alive_mongo_id text                      -- latest alive _id; pointer for live detail hydration
  first_seen_at  timestamptz NOT NULL
  last_seen_at   timestamptz NOT NULL
  removed_at     timestamptz               -- tombstone; NULL = present in Mongo
  synced_at      timestamptz NOT NULL
  index (host)
  index (program)
  index (removed_at)

sitemap_endpoints             -- projection of katana ∪ wayback, matched to a target
  id             bigint  PK
  target_id      bigint  REFERENCES sitemap_targets(id) ON DELETE CASCADE  -- NULLABLE (unmatched bucket)
  origin         text    NOT NULL          -- retained even when target_id IS NULL, for later attach
  url            text    NOT NULL          -- normalized full URL (query kept, fragment stripped)
  path           text    NOT NULL          -- tree node key
  method         text    NOT NULL          -- upcased; defaults to "GET" when the source omits it
  source         text    NOT NULL          -- 'katana' | 'wayback' | 'both'
  status_code    integer
  content_length bigint
  content_type   text
  url_digest     bytea   NOT NULL          -- sha256(normalized_url + "\0" + method)
  first_seen_at  timestamptz NOT NULL
  last_seen_at   timestamptz NOT NULL
  removed_at     timestamptz               -- tombstone
  synced_at      timestamptz NOT NULL
  unique (target_id, url_digest)                          -- dedups matched katana/wayback overlap
  unique (origin, url_digest) where target_id is null     -- dedups the unmatched bucket
  index (target_id, path)
  index (target_id, removed_at)
  index (origin) where target_id is null                  -- fast re-attach sweep
```

Design notes:

- **`targets` stays thin.** It is the FK anchor + grouping key + a pointer
  (`alive_mongo_id`) to the live doc. Rich asset detail (tech, headers, full
  http) is **not** copied — the target detail page keeps reading Mongo via
  `Targets::MongoSource`, so asset data has exactly one source of truth. Postgres
  owns only the *relation*.
- **`origin` is the join key**, not the Mongo `_id` (which churns when an asset
  is re-probed). `origin` is stable across re-scans.
- **`url_digest`** = `sha256(normalized_url + "\0" + method)`, unique per target.
  A katana row and a wayback row for the same normalized URL+method converge to a
  single endpoint whose `source` becomes `'both'`.
- **Nullable `target_id`** implements the unmatched bucket (see Matching). The
  partial index on `origin` keeps the re-attach sweep cheap.
- **`ON DELETE CASCADE`**: removing a whole target hard-deletes its endpoints
  (the asset is gone). Individual endpoints vanishing are tombstoned, not deleted
  (see Delete semantics).

The dedup constraint `(target_id, url_digest)` does not constrain rows where
`target_id IS NULL` (Postgres treats NULLs as distinct), so the unmatched bucket
is deduped by the separate partial `unique (origin, url_digest) where target_id
is null`. Both constraints are declared; exactly one applies to any given row
depending on whether it is matched.

## Origin normalization (`Sitemap::Origin`)

A single shared service owns origin derivation for **both** sides, so a target
origin and an endpoint origin are computed identically:

- Lowercase scheme and host.
- Fill implicit ports: `http` → 80, `https` → 443 when the URL omits a port.
- `origin = "#{scheme}://#{host}:#{port}"`.
- URL normalization for `url`/`url_digest`: lowercase scheme+host, normalized
  port, **path kept case-sensitive**, query string **retained**, fragment
  stripped.

## Matching (decisions locked)

For each endpoint document: derive its origin, then **exact-match** against
`targets.origin` (after implicit-port normalization). `http://host` and
`https://host` are distinct targets, consistent with the origin grain.

- **Grain:** one target = one origin (scheme+host+port), 1:1 with an alive asset.
- **Orphans (no matching target):** keep the endpoint with `target_id = NULL` and
  its `origin` retained — the **unmatched bucket**. A later reconciliation /
  stream pass attaches it (sets `target_id`) if an alive asset for that origin
  appears. Nothing is discarded.
- **Delete semantics:** **soft-delete / tombstone.** An endpoint that no longer
  appears in Mongo gets `removed_at` set and is retained (the sitemap UI can dim
  or hide "gone" endpoints — crawl history is preserved, Burp/Caido-style). A
  target that itself disappears is tombstoned; its endpoints hard-cascade via the
  FK when the target row is eventually deleted. (Target tombstone vs. hard delete
  timing: tombstone first, hard-delete only during an explicit purge — keeps the
  UI able to show recently-removed targets.)

## Sync — hybrid, delivered in two phases

Phased so the feature is functional after Phase 1; Phase 2 adds freshness.

### Phase 1 — reconciliation (`Sitemap::SyncJob`)

A Solid Queue recurring job mirroring the existing `Cves::SyncJob` /
`Cves::Sync` pattern (idempotent, per-unit error isolation, stats logging).
Scheduled in `config/recurring.yml`. One run:

1. **Targets:** upsert from `alive` (keyed by `origin`), refreshing
   `alive_mongo_id`, `program`, `last_seen_at`, `synced_at`. Incremental pull
   uses a high-water mark on `metadata.date`; a periodic full pass catches
   deletes.
2. **Endpoints:** for `katana` and `wayback`, stream docs (incremental by
   `timestamp` where available), normalize URL + origin, match to a target,
   upsert by `(target_id, url_digest)` (or the unmatched-bucket key), set
   `source`/`status_code`/`content_length`/`content_type`, bump `last_seen_at`.
3. **Tombstoning (delete detection):** set-difference — project the current key
   set from Mongo (cheap `_id`/URL projection) and mark Postgres rows not seen as
   `removed_at`. A previously-tombstoned row seen again is *un-tombstoned*
   (`removed_at = NULL`).
4. **Re-attach:** sweep the unmatched bucket (`target_id IS NULL`) and attach any
   whose origin now has a target.

Ordering (an endpoint seen before its target exists) resolves itself: targets
sync first, and the unmatched bucket + re-attach sweep handle the rest. This
phase alone makes the sitemap work end-to-end and is fully self-healing.

### Phase 2 — change-stream worker

A dedicated long-running process (Procfile entry in dev; its own process in prod)
tailing change streams on `alive`, `katana`, and `wayback`. It applies
`insert`/`update`/`replace`/`delete` to Postgres in near-real-time:

- **insert/update/replace** → the same upsert + match logic as Phase 1.
- **delete** → the change event carries only the document `_id`; map it back to
  the affected row(s) (via a stored source id) and tombstone. Anything the stream
  can't resolve is caught by the next reconciliation pass.
- **Resume tokens** persisted in a small `mongo_stream_cursors` table
  (`collection` PK, `resume_token`, `updated_at`) so the worker resumes exactly
  where it left off after a restart.

Phase 1's reconciliation job **stays on permanently** as the backstop that heals
any events missed while the worker was down or beyond the oplog window.

## Testing

- `Sitemap::Origin` — implicit-port fill, scheme/host lowercasing, URL
  normalization (query kept, fragment stripped), digest stability.
- Matching — exact-origin hit; orphan → `target_id NULL`; re-attach when a target
  appears; katana+wayback convergence to `source='both'`.
- `Sitemap::SyncJob` / reconciliation service — upsert idempotency; incremental
  high-water mark; tombstoning via set-difference; un-tombstone on reappearance;
  cascade on target delete. Double the Mongo collections (no live Mongo), per the
  house `stub_methods` pattern.
- Change-stream worker (Phase 2) — apply insert/update/delete to Postgres; resume
  from a persisted token. Mongo doubled; drive synthetic change events.
- Schema/migration — constraints and partial indexes behave (unique dedup incl.
  the unmatched-bucket variant).

## Non-goals (this spec)

- The **sitemap UI** — a follow-on that consumes this relation. Decided
  2026-07-18: it ships as **its own web department / page** (a dedicated
  left-nav entry and route, mirroring the other modules), not merely a tab on
  the target detail panel. Tree rendering, per-target endpoint lists, and the
  gone-endpoint (tombstone) toggle live there. Out of scope for *this* spec.
- Copying rich asset detail into Postgres (kept in Mongo, hydrated live).
- Any app-driven editing of endpoints/targets (would reintroduce two-way sync).
- Ingesting endpoint sources beyond `katana` and `wayback`.
- Storing katana `response.body` in Postgres (large; stays in Mongo, referenced
  by `alive_mongo_id`/source id if ever needed).

## Module placement

Follows the house module pattern: a `Sitemap` service namespace under
`web/app/services/sitemap/` (`Origin`, the reconciliation `Sync`, the matcher,
the stream worker). The ActiveRecord models are **namespaced to avoid colliding
with the existing `Target` PORO** (`web/app/models/target.rb`, the Mongo-backed
rich-detail read model): `Sitemap::Target` (table `sitemap_targets`) and
`Sitemap::Endpoint` (table `sitemap_endpoints`), under
`web/app/models/sitemap/`. `Sitemap::Target` is the relational projection; the
`Target` PORO stays the read path for rich asset detail, and the two are linked
by `alive_mongo_id` / `origin`. A migration creates the two tables +
`mongo_stream_cursors`, plus `config/recurring.yml` and Procfile wiring.
