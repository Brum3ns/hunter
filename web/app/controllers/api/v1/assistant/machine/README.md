# Assistant machine read controllers — module contract

Every Assistant read-only `list_*`/`get_*` tool pair is backed by a Rails
controller under `app/controllers/api/v1/assistant/machine/`. Adding a new
module is exactly these five mechanical edits (see the Go-side mirror at
`assistant/mcp/internal/modules/README.md` for the other half of the pair):

1. **Rails read source** — reuse the module's existing `MongoSource`/`Query`/AR
   scope. Do not build a new data layer for the Assistant; call the same
   source the public web/API controllers already use.
2. **Rails projection** — `app/services/assistant/machine/<m>_projection.rb`
   with `summary(record)` and `full(record)` returning explicit string-keyed
   allowlists. Never project a raw Mongo doc or raw ActiveRecord record.
   See `CveProjection` for the reference shape once the cves module lands.
3. **Rails controller** — `app/controllers/api/v1/assistant/machine/<m>_controller.rb`,
   `< Api::V1::Assistant::Machine::ReadController`. Should stay ~15 lines:
   `authorize_tool!`, fetch via the read source, project, then
   `list_response`/`detail_response` (or `machine_not_found` on a miss).
4. **Rails wiring** — add the two routes under the `assistant/machine`
   namespace; add the scope slug to `TurnGrant::READ_SCOPES` and the tool
   names to `Issuer::TOOLS`.
5. **Tests** — controller integration test stubbing the read source (no live
   Mongo/Postgres data), plus a projection unit test.

`ReadController` (this directory's `read_controller.rb`) supplies the shared
pieces so every module controller only needs its own read source + projection:

- `machine_page` / `machine_limit(max)` — pagination clamps.
- `list_response(reservation, count:, page:, limit:, items:)` /
  `detail_response(reservation, key:, value:)` — the
  `{correlation_id, ...}` response envelope.
- `machine_not_found(reservation)` — the shared 404 path.

Auth, scope enforcement, and budget accounting live one level up in
`Api::V1::Assistant::Machine::BaseController` (`authorize_tool!`,
`complete_machine_response!`, `machine_grant`) — do not duplicate them here.

The cves module (`CvesController` / `CveProjection`) is the intended first
concrete reference implementation of this contract; once it lands, prefer
copying its shape over re-deriving one from scratch.
