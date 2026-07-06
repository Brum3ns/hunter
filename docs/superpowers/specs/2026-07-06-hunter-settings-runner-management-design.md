# Hunter Settings — Runner Management Design

**Goal:** Let a signed-in user mint, list, and revoke **runner** identities from the
web UI (the Settings page), replacing the `bin/rails runners:create` rake step as
the primary way to provision a runner token.

**Context:** A runner is a machine identity (`Runner`, Postgres) that pulls curl
jobs from the pull API using a bearer token stored SHA-256 **digest-only**; the
raw token is shown once at mint time. Today the only way to mint one is the
`runners:create` rake task, and the raw token must be placed in the runner
container's env (`RUNNER_TOKEN`) by hand. This design moves minting into the web
UI. It does **not** change how the runner container receives the token: the
runner is a standalone container with no session, so its token must still live in
its environment. The UI generates/lists/revokes; the operator still copies the
raw token into the runner's env and restarts it.

## Scope

- **In:** a "Runners" section on the existing Settings page — list runners, create
  a runner (name + kinds), see the raw token **once**, revoke (permanent delete).
- **Out:** role-gating (the app has single-tier auth — every signed-in user can
  manage runners); editing an existing runner; any non-runner settings; changing
  how the runner container reads its token.

## Constraints

- Ruby 3.3.6, Rails 8, module namespace `Hunter`; app lives in `web/`.
- Reuse the existing `Runner` model and `Runner.generate(name:, kinds:)` (random
  token, digest stored, raw returned once). No new token scheme.
- Follow existing UI conventions (Tailwind zinc palette, `heroicon` helper, the
  `clipboard` Stimulus controller / `_code_block` chrome for copyable text).
- Tests must not hit live Mongo, a live runner, or the network. Postgres
  `hunter_test` is required (tests run in Docker).
- Commit author `Claude <noreply@anthropic.com>`; one-sentence commit messages;
  commit only when the user asks.

## Architecture

### Routes & auth

- Keep `get "settings", to: "settings#show"`.
- Add a settings-scoped resource:
  ```ruby
  namespace :settings do
    resources :runners, only: %i[create destroy]
  end
  ```
  → `POST /settings/runners` (`settings_runners_path`),
  `DELETE /settings/runners/:id` (`settings_runner_path`).
- Both `SettingsController` and `Settings::RunnersController` inherit the app's
  existing sign-in authentication (unauthenticated → redirect to sign in). No
  admin role exists, so no additional gating.

### Model

Add to `app/models/runner.rb`:

```ruby
has_many :runner_jobs, dependent: :nullify
```

On permanent delete this nulls the `runner_id` of any jobs the runner ran (the
column is already nullable and the FK has no cascade), so the delete succeeds and
the jobs' results/history survive — they simply lose the runner link. No
migration required.

### `SettingsController#show`

Loads the list for the view:

```ruby
def show
  @runners = Runner.order(:name)
end
```

### `Settings::RunnersController`

```ruby
module Settings
  class RunnersController < ApplicationController
    def create
      kinds = Array(params[:kinds]).map(&:to_s).reject(&:blank?)
      runner, raw = Runner.generate(name: params[:name].to_s.strip, kinds: kinds)
      redirect_to settings_path, flash: { runner_token: raw, runner_name: runner.name }
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      Runner.find(params[:id]).destroy
      redirect_to settings_path, notice: "Runner revoked."
    end
  end
end
```

- Empty `kinds` → `Runner.generate` builds a record with `kinds: []`; if the
  model rejects that it surfaces as a `RecordInvalid` alert. (If the current model
  allows empty kinds, the create form still defaults `curl` checked, and a
  presence guard on kinds is added to keep a runner from being minted that can
  claim nothing — see Open decisions.)
- Blank/duplicate name → `RecordInvalid` → alert, nothing minted.

### View — `settings/show.html.erb`, "Runners" section

1. **One-time token banner** — rendered only when `flash[:runner_token]` is set:
   the new runner's name plus its raw token in a copyable code block (existing
   `clipboard` controller), with a prominent "Copy this now — it is shown once and
   cannot be retrieved later" warning.
2. **Create form** — a `name` text field, a checkbox per `RunnerJob::KINDS`
   (`curl` pre-checked), and a "Create runner" submit.
3. **Runners table** — columns: name, kinds, last seen (relative time, or
   "never"), created; each row a "Revoke" `button_to` (DELETE) with a
   `data-turbo-confirm`. Empty state ("No runners yet.") when none.
4. **Helper note** — after minting: put the token in the runner's environment as
   `RUNNER_TOKEN` and restart the runner container; the token cannot be pushed
   from here.

## Data flow

1. User submits the create form → `Settings::RunnersController#create` →
   `Runner.generate` persists a runner (digest only) → raw token + name go into
   flash → redirect to Settings.
2. Settings re-renders; the one-time banner shows the raw token from flash;
   refreshing the page clears it (flash is single-use).
3. Operator copies the token into the runner container's `RUNNER_TOKEN` and
   restarts it; the runner then authenticates and claims jobs.
4. Revoke → `#destroy` nulls the runner's jobs and deletes the row; the token
   stops authenticating immediately (digest lookup misses).

## Error handling

- Unauthenticated request to any settings route → redirect to sign in (existing
  behavior).
- Blank or duplicate name, or (if enforced) empty kinds → `RecordInvalid` caught
  in `create` → redirect back with `flash[:alert]`; no runner minted.
- Revoking a non-existent id → `ActiveRecord::RecordNotFound` (standard 404).

## Testing

- **Model** (`runner_test.rb`): destroying a runner that has a `RunnerJob` nulls
  that job's `runner_id` and leaves the job present.
- **Controller integration** (`test/integration/settings/runners_test.rb`, service
  layer not needed — pure Postgres):
  - unauthenticated `POST`/`DELETE` → redirect to sign in;
  - `create` with a name mints exactly one runner and exposes the raw token in
    flash once (and the digest, not the raw, is stored);
  - `create` with a duplicate (or blank) name → alert, `Runner.count` unchanged;
  - `destroy` removes the runner and nulls an associated job's `runner_id`.
- **Settings show** (`test/integration/settings_test.rb` or extend existing):
  authenticated `GET /settings` renders and lists existing runners.

## Open decisions (resolve during planning)

- Whether `Runner` should validate `kinds` presence. Current model does not. The
  form defaults `curl` checked, so an empty submit is an edge case; add a
  `validates :kinds, presence: true` **only if** we want the alert path — decide
  when writing the plan (default: add it, since a runner with no kinds can claim
  nothing).

## Self-review

- **Spec coverage:** list/create/revoke → controller + view; token-once → flash
  banner; permanent delete without breaking job history → `dependent: :nullify`;
  auth → inherited; tests enumerated. ✓
- **No placeholders** except the single flagged "Open decision" (kinds presence),
  which is explicitly deferred to the plan with a default.
- **Consistency:** `settings_runners_path`/`settings_runner_path` used
  consistently; `Runner.generate` signature matches the existing model; frame/UI
  reuse (`clipboard`, `_code_block`) matches existing conventions.
