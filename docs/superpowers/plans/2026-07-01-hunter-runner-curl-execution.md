# Hunter Runner — Isolated curl Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user run a vulnerability's `curl` proof-of-concept from the drawer; the command executes inside a hardened runner container (never the Rails host) and its output streams back into the drawer.

**Architecture:** A `RunnerJob` row (Postgres, uuid pk) is the single source of truth. The web app enqueues a `curl` job; a dedicated runner container **pulls** work over an authenticated HTTP channel (`Runner` bearer token), executes it via a validated argv array (no shell), and posts the result back. The runner is structurally limited to job kinds in its `kinds` allowlist via a scoped atomic claim, so it is blind to future job kinds. The browser polls a Turbo Frame until the job reaches a terminal state.

**Tech Stack:** Rails 8, PostgreSQL (uuid + pgcrypto, string arrays, `FOR UPDATE SKIP LOCKED`), Hotwire (Turbo Frames/Streams + Stimulus), plain-Ruby runner agent (`net/http`, `open3`, `shellwords`, `timeout`), Docker Compose, Minitest with the repo's `stub_methods` helper.

## Global Constraints

- Ruby 3.3.6, Rails 8, Ruby module namespace is `Hunter`. The Rails app lives in `web/`; the repo root is its parent.
- **Two deliberate deviations from the committed design spec** (`docs/superpowers/specs/2026-07-01-hunter-runner-curl-execution-design.md`), both to avoid constant/command collisions:
  1. The safe-execution service is **`Sandbox::CurlCommand`** at `app/services/sandbox/curl_command.rb` (spec says `Runner::CurlCommand`). Reason: a top-level `class Runner < ApplicationRecord` (the model) cannot coexist with a top-level `module Runner` (the service namespace) — Ruby forbids one constant being both a Class and a Module. The runner-side copy is likewise `Sandbox::CurlCommand` in `runner/curl_command.rb`.
  2. The rake namespace is **`runners:`** (`runners:create`, `runners:reap`), not `runner:`. Reason: `bin/rails runner` is a built-in Rails command; a `runner:` task namespace is confusing and can shadow it.
- API auth: `Api::BaseController` accepts session cookie **or** `Authorization: Bearer <token>`. Runner endpoints authenticate against **`Runner`** (not `ApiToken`); user/API tokens are rejected there and runner tokens are rejected on user endpoints.
- Tests must NOT hit live Mongo, a live runner, or the live network. Stub the service layer with the `stub_methods(target, mapping)` helper in `web/test/test_helper.rb`. Postgres `hunter_test` is required (tests run in Docker only — the implementer cannot assume a local DB).
- Migrations use `ActiveRecord::Migration[8.1]` (match the existing `20260630000001_create_api_tokens.rb`).
- Commit author `Claude <noreply@anthropic.com>`; one-sentence commit messages; commit only when the user asks.
- Truncation, timeouts, and output caps read from ENV with the defaults named in each task.

---

### Task 1: `Sandbox::CurlCommand` — safe validation + execution

The security-critical unit. Pure Ruby, no Rails. The identical logic lives in two places (defense in depth): `web/app/services/sandbox/curl_command.rb` (enqueue-time validation) and `runner/curl_command.rb` (execution-time gate, Task 7). This task builds the web copy and its tests.

**Files:**
- Create: `web/app/services/sandbox/curl_command.rb`
- Test: `web/test/services/sandbox/curl_command_test.rb`

**Interfaces:**
- Produces:
  - `Sandbox::CurlCommand.validate(command) -> [Boolean, Array<String> | String]` — `[true, argv]` or `[false, reason]`.
  - `Sandbox::CurlCommand.execute(command, max_time:, max_output:) -> Sandbox::CurlCommand::Result` — validates then runs, never execs invalid input.
  - `Sandbox::CurlCommand::Result` = `Struct.new(:exit_status, :stdout, :stderr, :error, :duration_ms, :output_truncated, keyword_init: true)`.

- [ ] **Step 1: Write the failing test**

Create `web/test/services/sandbox/curl_command_test.rb`:

```ruby
require "test_helper"

class Sandbox::CurlCommandTest < ActiveSupport::TestCase
  def validate(cmd) = Sandbox::CurlCommand.validate(cmd)

  test "accepts a plain https curl" do
    ok, argv = validate("curl https://example.com/api")
    assert ok
    assert_equal %w[curl https://example.com/api], argv
  end

  test "accepts curl with --url and safe flags" do
    ok, argv = validate("curl -sS -H 'Accept: application/json' --url https://example.com")
    assert ok
    assert_includes argv, "https://example.com"
  end

  test "rejects empty command" do
    ok, reason = validate("   ")
    refute ok
    assert_match(/empty/i, reason)
  end

  test "rejects non-curl program" do
    ok, reason = validate("wget https://example.com")
    refute ok
    assert_match(/curl/i, reason)
  end

  test "rejects unparseable command" do
    ok, reason = validate("curl 'unterminated")
    refute ok
    assert_match(/parse/i, reason)
  end

  test "rejects a newline in the command" do
    ok, reason = validate("curl https://example.com\nrm -rf /")
    refute ok
    assert_match(/newline|invalid/i, reason)
  end

  test "rejects non-http schemes" do
    ok, reason = validate("curl file:///etc/passwd")
    refute ok
    assert_match(/http/i, reason)
  end

  test "rejects when no http url is present" do
    ok, reason = validate("curl -sS")
    refute ok
    assert_match(/url/i, reason)
  end

  test "rejects output-writing flags" do
    %w[-o --output -O --remote-name -K --config -D --dump-header -c --cookie-jar].each do |flag|
      ok, reason = validate("curl #{flag} x https://example.com")
      refute ok, "expected #{flag} to be rejected"
      assert_match(/not allowed|denied|flag/i, reason)
    end
  end

  test "rejects data flags that read a file" do
    ok, reason = validate("curl -d @/etc/passwd https://example.com")
    refute ok
    assert_match(/file/i, reason)
  end

  test "rejects too many arguments" do
    args = (["curl"] + Array.new(80, "-H") + ["https://example.com"]).join(" ")
    ok, reason = validate(args)
    refute ok
    assert_match(/many|long/i, reason)
  end

  test "execute never runs invalid input" do
    called = false
    Sandbox::CurlCommand.stub(:capture, ->(*) { called = true; ["", "", 0] }) do
      result = Sandbox::CurlCommand.execute("curl file:///etc/passwd", max_time: 5, max_output: 1000)
      refute called
      refute_nil result.error
      assert_nil result.exit_status
    end
  end

  test "execute injects safety flags and returns a Result" do
    seen = nil
    Sandbox::CurlCommand.stub(:capture, ->(argv, **) { seen = argv; ["body", "", 0] }) do
      result = Sandbox::CurlCommand.execute("curl https://example.com", max_time: 7, max_output: 1000)
      assert_equal 0, result.exit_status
      assert_equal "body", result.stdout
      assert_includes seen, "--max-time"
      assert_includes seen, "7"
      assert_includes seen, "-sS"
    end
  end

  test "execute truncates output over the cap" do
    Sandbox::CurlCommand.stub(:capture, ->(*) { ["x" * 5000, "", 0] }) do
      result = Sandbox::CurlCommand.execute("curl https://example.com", max_time: 5, max_output: 100)
      assert_equal 100, result.stdout.bytesize
      assert result.output_truncated
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bin/rails test test/services/sandbox/curl_command_test.rb`
Expected: FAIL — `uninitialized constant Sandbox`.

- [ ] **Step 3: Write the minimal implementation**

Create `web/app/services/sandbox/curl_command.rb`:

```ruby
require "shellwords"
require "open3"
require "timeout"

# Validates and safely executes an attacker-influenced `curl` command.
#
# No shell is ever involved: the command is parsed into an argv array and run
# via Open3.capture3(*argv). Only `curl` against http/https is permitted, and a
# denylist blocks every flag that would let curl touch the filesystem. This file
# is duplicated at runner/curl_command.rb (as the same Sandbox::CurlCommand) so
# the runner container re-validates before executing — defense in depth.
module Sandbox
  module CurlCommand
    module_function

    MAX_ARGS = 60
    MAX_LENGTH = 8_000

    Result = Struct.new(
      :exit_status, :stdout, :stderr, :error, :duration_ms, :output_truncated,
      keyword_init: true
    )

    # Flags that write the filesystem or read local files.
    DENIED_FLAGS = %w[
      -o --output -O --remote-name --output-dir
      -T --upload-file -K --config -D --dump-header
      -c --cookie-jar --trace --trace-ascii
    ].freeze

    DATA_FLAGS = %w[-d --data --data-raw --data-binary --data-urlencode --data-ascii -F --form].freeze

    def validate(command)
      command = command.to_s
      return [false, "command is empty"] if command.strip.empty?
      return [false, "command is too long"] if command.length > MAX_LENGTH
      return [false, "command contains a newline (invalid)"] if command.match?(/[\r\n]/)
      return [false, "command contains a NUL byte (invalid)"] if command.include?("\u0000")

      begin
        argv = Shellwords.split(command)
      rescue ArgumentError
        return [false, "command could not be parsed"]
      end

      return [false, "command is empty"] if argv.empty?
      return [false, "command has too many arguments"] if argv.length > MAX_ARGS
      return [false, "command must invoke curl"] unless File.basename(argv[0]) == "curl"

      argv[1..].each_with_index do |arg, i|
        prev = argv[i] # argv[i] is the element before argv[1..][i]
        return [false, "flag #{arg} is not allowed"] if DENIED_FLAGS.include?(arg)
        if DATA_FLAGS.include?(prev) && arg.start_with?("@")
          return [false, "reading data from a file is not allowed"]
        end
        if arg.include?("://") && !arg.match?(%r{\Ahttps?://}i)
          return [false, "only http/https URLs are allowed"]
        end
      end

      urls = argv.select { |a| a.match?(%r{\Ahttps?://}i) }
      return [false, "no http/https URL found"] if urls.empty?

      [true, argv]
    end

    def execute(command, max_time:, max_output:)
      ok, argv_or_reason = validate(command)
      return Result.new(error: argv_or_reason, output_truncated: false) unless ok

      argv = with_safety_flags(argv_or_reason, max_time:, max_output:)
      started = monotonic_ms

      begin
        stdout, stderr, status = Timeout.timeout(max_time + 5) { capture(argv, binmode: true) }
      rescue Timeout::Error
        return Result.new(error: "timed out after #{max_time}s", duration_ms: monotonic_ms - started, output_truncated: false)
      rescue StandardError => e
        return Result.new(error: "execution failed: #{e.class}", duration_ms: monotonic_ms - started, output_truncated: false)
      end

      out, out_trunc = clip(stdout, max_output)
      err, err_trunc = clip(stderr, max_output)
      exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : status

      Result.new(
        exit_status: exit_status,
        stdout: out,
        stderr: err,
        error: nil,
        duration_ms: monotonic_ms - started,
        output_truncated: out_trunc || err_trunc
      )
    end

    # Seam for stubbing in tests. Returns [stdout, stderr, exit_status_int].
    def capture(argv, binmode: false)
      stdout, stderr, status = Open3.capture3(*argv, binmode: binmode)
      [stdout, stderr, status]
    end

    def with_safety_flags(argv, max_time:, max_output:)
      argv = argv.dup
      argv << "-sS" unless argv.include?("-sS") || argv.include?("--silent")
      argv.push("--max-time", max_time.to_s) unless argv.include?("--max-time")
      argv.push("--connect-timeout", "10") unless argv.include?("--connect-timeout")
      argv.push("--max-filesize", max_output.to_s) unless argv.include?("--max-filesize")
      argv
    end

    def clip(str, max_bytes)
      str = str.to_s.b
      return [str, false] if str.bytesize <= max_bytes

      [str.byteslice(0, max_bytes), true]
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails test test/services/sandbox/curl_command_test.rb`
Expected: PASS (all assertions).

Note: `Open3.capture3` accepts `binmode:` in Ruby 3.3. `Result` fields not set default to `nil`; `exit_status` stays `nil` on validation failure as the test asserts.

- [ ] **Step 5: Commit**

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/services/sandbox/curl_command.rb test/services/sandbox/curl_command_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Sandbox::CurlCommand for safe curl validation and execution"
```

---

### Task 2: `Runner` model + migration — scoped machine identity

**Files:**
- Create: `web/db/migrate/20260701000001_create_runners.rb`
- Create: `web/app/models/runner.rb`
- Test: `web/test/models/runner_test.rb`

**Interfaces:**
- Produces:
  - `Runner.authenticate(raw) -> Runner | nil` (touches `last_seen_at` on hit).
  - `Runner.generate(name:, kinds:) -> [Runner, String]` (record + raw token; raw shown once).
  - `Runner#kinds -> Array<String>`.

- [ ] **Step 1: Write the failing test**

Create `web/test/models/runner_test.rb`:

```ruby
require "test_helper"

class RunnerTest < ActiveSupport::TestCase
  test "generate returns a record and a raw token, stored digest-only" do
    runner, raw = Runner.generate(name: "curl-runner", kinds: %w[curl])
    assert runner.persisted?
    assert raw.present?
    assert_not_equal raw, runner.token_digest
    assert_equal %w[curl], runner.kinds
  end

  test "authenticate returns the runner for a valid token and touches last_seen_at" do
    runner, raw = Runner.generate(name: "curl-runner", kinds: %w[curl])
    assert_nil runner.last_seen_at
    found = Runner.authenticate(raw)
    assert_equal runner.id, found.id
    assert_not_nil found.last_seen_at
  end

  test "authenticate returns nil for an unknown token" do
    Runner.generate(name: "curl-runner", kinds: %w[curl])
    assert_nil Runner.authenticate("nope")
  end

  test "authenticate returns nil for a blank token" do
    assert_nil Runner.authenticate("")
    assert_nil Runner.authenticate(nil)
  end

  test "name must be unique" do
    Runner.generate(name: "dup", kinds: %w[curl])
    assert_raises(ActiveRecord::RecordInvalid) { Runner.generate(name: "dup", kinds: %w[curl]) }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bin/rails test test/models/runner_test.rb`
Expected: FAIL — table/model missing.

- [ ] **Step 3: Write the migration and model**

Create `web/db/migrate/20260701000001_create_runners.rb`:

```ruby
class CreateRunners < ActiveRecord::Migration[8.1]
  def change
    create_table :runners do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :kinds, array: true, null: false, default: []
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :runners, :name, unique: true
    add_index :runners, :token_digest, unique: true
  end
end
```

Create `web/app/models/runner.rb`:

```ruby
require "securerandom"
require "digest"

# A runner is a machine identity (not a user) that pulls and executes jobs whose
# kind is in its `kinds` allowlist. Tokens are stored SHA-256 digest-only, minted
# out-of-band via `bin/rails runners:create`.
class Runner < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true

  def self.generate(name:, kinds:)
    raw = SecureRandom.urlsafe_base64(32)
    record = create!(name: name, kinds: Array(kinds).map(&:to_s), token_digest: digest(raw))
    [record, raw]
  end

  def self.authenticate(raw)
    raw = raw.to_s
    return nil if raw.empty?

    runner = find_by(token_digest: digest(raw))
    runner&.update_column(:last_seen_at, Time.current)
    runner
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails db:migrate && bin/rails test test/models/runner_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/models/runner.rb db/migrate/20260701000001_create_runners.rb db/schema.rb test/models/runner_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Runner model for scoped runner machine identity"
```

---

### Task 3: `RunnerJob` model + migration — jobs with a scoped atomic claim

**Files:**
- Create: `web/db/migrate/20260701000002_create_runner_jobs.rb`
- Create: `web/app/models/runner_job.rb`
- Test: `web/test/models/runner_job_test.rb`

**Interfaces:**
- Consumes: `Runner` (Task 2), `User` (existing).
- Produces:
  - `RunnerJob::KINDS = %w[curl]`, `RunnerJob::STATUSES = %w[queued running succeeded failed]`.
  - `RunnerJob.claim!(runner) -> RunnerJob | nil` — atomic, scoped to `runner.kinds`.
  - `RunnerJob#record_result!(exit_status:, stdout:, stderr:, error:, duration_ms:, output_truncated:)`.
  - `RunnerJob#reap_if_stale! -> Boolean`, `RunnerJob.reap_stale! -> Integer`.
  - `RunnerJob#terminal? -> Boolean`.

- [ ] **Step 1: Write the failing test**

Create `web/test/models/runner_job_test.rb`:

```ruby
require "test_helper"

class RunnerJobTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @curl_runner, = Runner.generate(name: "curl-runner", kinds: %w[curl])
  end

  def queue(kind: "curl", command: "curl https://example.com")
    RunnerJob.create!(kind: kind, command: command, vulnerability_id: "v1", requested_by: @user)
  end

  test "kind must be in the allowlist" do
    assert_raises(ActiveRecord::RecordInvalid) do
      RunnerJob.create!(kind: "nuclei", command: "x", vulnerability_id: "v", requested_by: @user)
    end
  end

  test "claim! returns the oldest queued job and marks it running" do
    first = queue
    queue
    claimed = RunnerJob.claim!(@curl_runner)
    assert_equal first.id, claimed.id
    assert_equal "running", claimed.status
    assert_equal @curl_runner.id, claimed.runner_id
    assert_not_nil claimed.claimed_at
  end

  test "claim! returns nil when no queued job matches" do
    assert_nil RunnerJob.claim!(@curl_runner)
  end

  test "claim! never sees a job whose kind is out of scope" do
    # Seed a nuclei job directly (bypass validation) and a scoped runner.
    RunnerJob.insert!({ kind: "nuclei", command: "x", vulnerability_id: "v", requested_by_id: @user.id, status: "queued", created_at: Time.current, updated_at: Time.current })
    assert_nil RunnerJob.claim!(@curl_runner), "curl runner must not claim a nuclei job"
  end

  test "record_result! marks succeeded on clean exit" do
    job = queue
    RunnerJob.claim!(@curl_runner)
    job.reload.record_result!(exit_status: 0, stdout: "ok", stderr: "", error: nil, duration_ms: 12, output_truncated: false)
    assert_equal "succeeded", job.reload.status
    assert_not_nil job.finished_at
  end

  test "record_result! marks failed on nonzero exit or error" do
    job = queue
    RunnerJob.claim!(@curl_runner)
    job.reload.record_result!(exit_status: 7, stdout: "", stderr: "boom", error: nil, duration_ms: 1, output_truncated: false)
    assert_equal "failed", job.reload.status
  end

  test "reap_if_stale! fails a job stuck running past the TTL" do
    job = queue
    RunnerJob.claim!(@curl_runner)
    job.reload.update_column(:started_at, 1.hour.ago)
    assert job.reap_if_stale!
    assert_equal "failed", job.reload.status
    assert_match(/timed out/i, job.error)
  end

  test "reap_if_stale! leaves a fresh running job alone" do
    job = queue
    RunnerJob.claim!(@curl_runner)
    refute job.reload.reap_if_stale!
    assert_equal "running", job.reload.status
  end

  test "terminal? is true only for succeeded/failed" do
    job = queue
    refute job.terminal?
    job.update_column(:status, "succeeded")
    assert job.terminal?
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bin/rails test test/models/runner_job_test.rb`
Expected: FAIL — table/model missing.

- [ ] **Step 3: Write the migration and model**

Create `web/db/migrate/20260701000002_create_runner_jobs.rb`:

```ruby
class CreateRunnerJobs < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :runner_jobs, id: :uuid do |t|
      t.string   :kind, null: false
      t.text     :command, null: false
      t.string   :vulnerability_id, null: false
      t.string   :status, null: false, default: "queued"
      t.integer  :exit_status
      t.text     :stdout
      t.text     :stderr
      t.boolean  :output_truncated, null: false, default: false
      t.string   :error
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :runner, foreign_key: true
      t.integer  :duration_ms
      t.datetime :claimed_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :runner_jobs, %i[status kind created_at]
  end
end
```

Create `web/app/models/runner_job.rb`:

```ruby
# A unit of work executed by a Runner. `queued -> running -> succeeded|failed`;
# a job can also fail directly from queued at enqueue-time validation. The claim
# is atomic and scoped to the runner's kinds, so a runner is structurally unable
# to observe jobs outside its allowlist.
class RunnerJob < ApplicationRecord
  KINDS = %w[curl].freeze
  STATUSES = %w[queued running succeeded failed].freeze

  # A running job older than this is presumed dead (runner crash / lost result).
  TTL_SECONDS = Integer(ENV.fetch("RUNNER_JOB_TTL", 90))

  belongs_to :requested_by, class_name: "User"
  belongs_to :runner, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :command, presence: true
  validates :vulnerability_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  def self.claim!(runner)
    kinds = Array(runner.kinds)
    return nil if kinds.empty?

    row = connection.exec_query(<<~SQL, "RunnerJob Claim", [runner.id, kinds.to_s.gsub(/\A\[|\]\z/, "")], prepare: false).first
      UPDATE runner_jobs SET status = 'running', runner_id = $1, claimed_at = now(), started_at = now(), updated_at = now()
      WHERE id = (
        SELECT id FROM runner_jobs
        WHERE status = 'queued' AND kind = ANY(string_to_array($2, ','))
        ORDER BY created_at
        FOR UPDATE SKIP LOCKED
        LIMIT 1
      )
      RETURNING id
    SQL

    row && find(row["id"])
  end

  def record_result!(exit_status:, stdout:, stderr:, error:, duration_ms:, output_truncated:)
    succeeded = error.blank? && exit_status.to_i.zero?
    update!(
      status: succeeded ? "succeeded" : "failed",
      exit_status: exit_status,
      stdout: stdout,
      stderr: stderr,
      error: error,
      duration_ms: duration_ms,
      output_truncated: !!output_truncated,
      finished_at: Time.current
    )
  end

  def reap_if_stale!
    return false unless status == "running"
    return false unless started_at && started_at < TTL_SECONDS.seconds.ago

    update!(status: "failed", error: "runner timed out", finished_at: Time.current)
    true
  end

  def self.reap_stale!
    where(status: "running").where(started_at: ..TTL_SECONDS.seconds.ago)
      .update_all(status: "failed", error: "runner timed out", finished_at: Time.current)
  end

  def terminal?
    status == "succeeded" || status == "failed"
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails db:migrate && bin/rails test test/models/runner_job_test.rb`
Expected: PASS.

Note on the claim SQL: `kinds` (a Ruby array) is passed as a comma-joined string and re-split in Postgres with `string_to_array($2, ',')`, then matched with `kind = ANY(...)`. This keeps the query a single prepared statement without array-binding gymnastics. Job kinds never contain commas (`KINDS` allowlist), so the join is safe.

- [ ] **Step 5: Commit**

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/models/runner_job.rb db/migrate/20260701000002_create_runner_jobs.rb db/schema.rb test/models/runner_job_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add RunnerJob model with kind-scoped atomic claim and staleness reaper"
```

---

### Task 4: Rake tasks — `runners:create` and `runners:reap`

**Files:**
- Create: `web/lib/tasks/runner.rake`
- Test: `web/test/lib/tasks/runner_rake_test.rb`

**Interfaces:**
- Consumes: `Runner` (Task 2), `RunnerJob` (Task 3).
- Produces: `runners:create` (ENV `NAME`, `KINDS`), `runners:reap`.

- [ ] **Step 1: Write the failing test**

Create `web/test/lib/tasks/runner_rake_test.rb`:

```ruby
require "test_helper"
require "rake"

class RunnerRakeTest < ActiveSupport::TestCase
  setup do
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake.load_rakefile(Rails.root.join("lib/tasks/runner.rake").to_s)
    Rake::Task.define_task(:environment)
  end

  test "runners:create mints a runner and prints the raw token once" do
    ENV["NAME"] = "curl-runner"
    ENV["KINDS"] = "curl"
    out, = capture_io { @rake["runners:create"].invoke }
    assert Runner.find_by(name: "curl-runner")
    assert_match(/token/i, out)
  ensure
    ENV.delete("NAME"); ENV.delete("KINDS")
  end

  test "runners:reap fails stale running jobs" do
    user = users(:one)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "v", requested_by: user, status: "running", started_at: 1.hour.ago)
    capture_io { @rake["runners:reap"].invoke }
    assert_equal "failed", job.reload.status
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bin/rails test test/lib/tasks/runner_rake_test.rb`
Expected: FAIL — rakefile missing.

- [ ] **Step 3: Write the rake tasks**

Create `web/lib/tasks/runner.rake`:

```ruby
# Namespaced `runners:` (not `runner:`) to avoid confusion with the built-in
# `bin/rails runner` command.
namespace :runners do
  desc "Mint a runner identity: NAME=curl-runner KINDS=curl[,nuclei]"
  task create: :environment do
    name = ENV["NAME"].to_s.strip
    kinds = ENV["KINDS"].to_s.split(",").map(&:strip).reject(&:empty?)
    abort "NAME is required" if name.empty?
    abort "KINDS is required (comma-separated)" if kinds.empty?

    runner, raw = Runner.generate(name: name, kinds: kinds)
    puts "Created runner ##{runner.id} '#{runner.name}' (kinds: #{runner.kinds.join(', ')})"
    puts "Runner token (shown once, store it now):"
    puts raw
  end

  desc "Fail runner jobs stuck running past the TTL"
  task reap: :environment do
    n = RunnerJob.reap_stale!
    puts "Reaped #{n} stale job(s)."
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails test test/lib/tasks/runner_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add lib/tasks/runner.rake test/lib/tasks/runner_rake_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add runners:create and runners:reap rake tasks"
```

---

### Task 5: Runner API — `Api::V1::Runner::JobsController` + `Current.runner` + routes

**Files:**
- Create: `web/app/controllers/api/v1/runner/jobs_controller.rb`
- Modify: `web/app/models/current.rb` (add `:runner` attribute)
- Modify: `web/config/routes.rb` (add runner API namespace)
- Test: `web/test/integration/api/runner/jobs_test.rb`

**Interfaces:**
- Consumes: `Runner` (Task 2), `RunnerJob` (Task 3), `Api::V1::BaseController` (existing), `bearer_token` (existing in `Api::BaseController`).
- Produces: `POST /api/v1/runner/jobs/claim`, `POST /api/v1/runner/jobs/:id/result`; `Current.runner`.

- [ ] **Step 1: Write the failing test**

Create `web/test/integration/api/runner/jobs_test.rb`:

```ruby
require "test_helper"

class Api::Runner::JobsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @runner, @raw = Runner.generate(name: "curl-runner", kinds: %w[curl])
  end

  def auth = { "Authorization" => "Bearer #{@raw}" }

  def queue(kind: "curl")
    RunnerJob.create!(kind: kind, command: "curl https://example.com", vulnerability_id: "v1", requested_by: @user)
  end

  test "claim requires a runner bearer token" do
    post "/api/v1/runner/jobs/claim"
    assert_response :unauthorized
  end

  test "a user API token cannot claim" do
    _, raw = ApiToken.generate(user: @user, name: "t")
    post "/api/v1/runner/jobs/claim", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :unauthorized
  end

  test "claim returns the oldest queued job and marks it running" do
    job = queue
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal job.id, body["id"]
    assert_equal "curl", body["kind"]
    assert_equal "running", job.reload.status
  end

  test "claim returns 204 when nothing is queued" do
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :no_content
  end

  test "claim never returns an out-of-scope kind" do
    RunnerJob.insert!({ kind: "nuclei", command: "x", vulnerability_id: "v", requested_by_id: @user.id, status: "queued", created_at: Time.current, updated_at: Time.current })
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :no_content
  end

  test "result records terminal state for an owned running job" do
    job = queue
    RunnerJob.claim!(@runner)
    post "/api/v1/runner/jobs/#{job.id}/result", headers: auth,
      params: { exit_status: 0, stdout: "ok", stderr: "", duration_ms: 5, output_truncated: false }
    assert_response :success
    assert_equal "succeeded", job.reload.status
  end

  test "result 404s for a job the runner did not claim" do
    other, = Runner.generate(name: "other", kinds: %w[curl])
    job = queue
    RunnerJob.claim!(other)
    post "/api/v1/runner/jobs/#{job.id}/result", headers: auth,
      params: { exit_status: 0, stdout: "x", stderr: "", duration_ms: 1 }
    assert_response :not_found
    assert_equal "running", job.reload.status
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bin/rails test test/integration/api/runner/jobs_test.rb`
Expected: FAIL — route/controller missing.

- [ ] **Step 3: Add `Current.runner`, the controller, and routes**

Edit `web/app/models/current.rb` — add `:runner` to the attribute list (keep `user` resolution unchanged):

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user, :runner

  def user
    api_user || session&.user
  end
end
```

Create `web/app/controllers/api/v1/runner/jobs_controller.rb`:

```ruby
module Api
  module V1
    module Runner
      # Pull endpoints for runner containers. Authenticated against the Runner
      # machine identity (NOT ApiToken); user tokens are rejected here.
      class JobsController < Api::V1::BaseController
        skip_before_action :authenticate_api!
        before_action :authenticate_runner!

        def claim
          job = ::RunnerJob.claim!(Current.runner)
          return head :no_content unless job

          render json: { id: job.id, kind: job.kind, command: job.command }
        end

        def result
          job = ::RunnerJob.find_by(id: params[:id], runner_id: Current.runner.id, status: "running")
          return render_not_found unless job

          job.record_result!(
            exit_status: params[:exit_status],
            stdout: params[:stdout].to_s,
            stderr: params[:stderr].to_s,
            error: params[:error].presence,
            duration_ms: params[:duration_ms],
            output_truncated: ActiveModel::Type::Boolean.new.cast(params[:output_truncated])
          )
          render json: { ok: true }
        end

        private

        def authenticate_runner!
          runner = ::Runner.authenticate(bearer_token)
          return request_authentication unless runner

          Current.runner = runner
        end
      end
    end
  end
end
```

Edit `web/config/routes.rb` — add the runner namespace inside `namespace :api { namespace :v1 { ... } }`, as a sibling of the vulnerabilities resources:

```ruby
namespace :runner do
  post "jobs/claim",      to: "jobs#claim"
  post "jobs/:id/result", to: "jobs#result"
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/api/runner/jobs_test.rb`
Expected: PASS.

Note: `request_authentication` and `bearer_token` already exist in `Api::BaseController`. `render_not_found` exists in `Api::V1::BaseController`. `skip_before_action :authenticate_api!` removes the user/token auth so only `authenticate_runner!` gates these actions.

- [ ] **Step 5: Commit**

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/controllers/api/v1/runner/jobs_controller.rb app/models/current.rb config/routes.rb test/integration/api/runner/jobs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add runner pull API for claiming and reporting curl jobs"
```

---

### Task 6: Web enqueue + polling result — `Vulnerabilities::RunsController`, views, Run button

**Files:**
- Create: `web/app/controllers/vulnerabilities/runs_controller.rb`
- Create: `web/app/views/vulnerabilities/runs/create.turbo_stream.erb`
- Create: `web/app/views/vulnerabilities/runs/show.html.erb`
- Create: `web/app/views/vulnerabilities/runs/_result.html.erb`
- Create: `web/app/javascript/controllers/poller_controller.js`
- Modify: `web/app/views/vulnerabilities/details/_panel.html.erb` (Run button + run frame)
- Modify: `web/config/routes.rb` (vuln runs routes, before the catch-all `get "/:id"`)
- Test: `web/test/integration/vulnerabilities/runs_test.rb`

**Interfaces:**
- Consumes: `Vulnerabilities::MongoSource.find(id)` (existing), `Sandbox::CurlCommand.validate` (Task 1), `RunnerJob` (Task 3), `Vulnerabilities::BaseController` (existing), the existing `details/_code_block.html.erb` partial, `Current.user`.
- Produces: `POST /vulnerabilities/:id/runs` (`vulnerabilities_runs_path`), `GET /vulnerabilities/:id/runs/:job_id` (`vulnerabilities_run_path`); Turbo Frame id `runner_run_<vuln_id>`.

- [ ] **Step 1: Write the failing test**

Create `web/test/integration/vulnerabilities/runs_test.rb`:

```ruby
require "test_helper"

class Vulnerabilities::RunsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @doc = { "id" => "abc", "poc" => { "curl" => "curl https://example.com" } }
  end

  test "unauthenticated create redirects to sign in" do
    post "/vulnerabilities/abc/runs"
    assert_response :redirect
  end

  test "create enqueues a curl job and returns a turbo stream" do
    sign_in_as(@user)
    stub_methods(Vulnerabilities::MongoSource, find: @doc) do
      assert_difference -> { RunnerJob.count }, 1 do
        post "/vulnerabilities/abc/runs", headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
    end
    assert_response :success
    job = RunnerJob.last
    assert_equal "queued", job.status
    assert_equal "abc", job.vulnerability_id
    assert_equal @user.id, job.requested_by_id
  end

  test "create with an invalid curl records a failed job" do
    sign_in_as(@user)
    bad = { "id" => "abc", "poc" => { "curl" => "curl file:///etc/passwd" } }
    stub_methods(Vulnerabilities::MongoSource, find: bad) do
      post "/vulnerabilities/abc/runs", headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_equal "failed", RunnerJob.last.status
  end

  test "create 404s when the vuln is missing" do
    sign_in_as(@user)
    stub_methods(Vulnerabilities::MongoSource, find: nil) do
      post "/vulnerabilities/abc/runs"
    end
    assert_response :not_found
  end

  test "create 422s when there is no curl poc" do
    sign_in_as(@user)
    stub_methods(Vulnerabilities::MongoSource, find: { "id" => "abc", "poc" => {} }) do
      post "/vulnerabilities/abc/runs"
    end
    assert_response :unprocessable_entity
  end

  test "show renders the job frame and reaps a stale job" do
    sign_in_as(@user)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "abc", requested_by: @user, status: "running", started_at: 1.hour.ago)
    get "/vulnerabilities/abc/runs/#{job.id}"
    assert_response :success
    assert_equal "failed", job.reload.status
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bin/rails test test/integration/vulnerabilities/runs_test.rb`
Expected: FAIL — route/controller missing.

- [ ] **Step 3: Write the controller, views, poller, routes, and Run button**

Create `web/app/controllers/vulnerabilities/runs_controller.rb`:

```ruby
module Vulnerabilities
  class RunsController < Vulnerabilities::BaseController
    def create
      doc = Vulnerabilities::MongoSource.find(params[:id])
      return head :not_found unless doc

      command = doc.dig("poc", "curl").to_s
      return head :unprocessable_entity if command.strip.empty?

      ok, reason = Sandbox::CurlCommand.validate(command)
      @job = RunnerJob.create!(
        kind: "curl",
        command: command,
        vulnerability_id: params[:id],
        requested_by: Current.user,
        status: ok ? "queued" : "failed",
        error: ok ? nil : reason,
        finished_at: ok ? nil : Time.current
      )

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to vulnerability_path(params[:id]) }
      end
    end

    def show
      @job = RunnerJob.find_by(id: params[:job_id], vulnerability_id: params[:id])
      return head :not_found unless @job

      @job.reap_if_stale!
      render "vulnerabilities/runs/_result", layout: false, locals: { job: @job }
    end
  end
end
```

Create `web/app/views/vulnerabilities/runs/_result.html.erb`:

```erb
<%# Self-polling frame. While non-terminal it carries the `poller` controller and
    reloads itself; on terminal state the poller is omitted so polling stops. %>
<%= turbo_frame_tag "runner_run_#{job.vulnerability_id}",
      src: (job.terminal? ? nil : vulnerabilities_run_path(job.vulnerability_id, job.id)),
      data: (job.terminal? ? {} : { controller: "poller", poller_interval_value: 1500 }) do %>
  <div class="rounded-lg border border-zinc-200 dark:border-zinc-800">
    <div class="flex items-center gap-2 border-b border-zinc-200 px-3 py-2 text-xs dark:border-zinc-800">
      <span class="inline-flex items-center rounded-full px-2 py-0.5 font-medium ring-1 ring-inset
        <%= case job.status
              when "succeeded" then "bg-emerald-50 text-emerald-700 ring-emerald-600/20 dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-400/20"
              when "failed"    then "bg-rose-50 text-rose-700 ring-rose-600/20 dark:bg-rose-500/10 dark:text-rose-300 dark:ring-rose-400/20"
              when "running"   then "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-500/10 dark:text-amber-300 dark:ring-amber-400/20"
              else                  "bg-zinc-100 text-zinc-600 ring-zinc-500/20 dark:bg-zinc-800 dark:text-zinc-300 dark:ring-zinc-500/20"
            end %>">
        <%= job.status %>
      </span>
      <% unless job.exit_status.nil? %><span class="text-zinc-500 dark:text-zinc-400">exit <%= job.exit_status %></span><% end %>
      <% if job.duration_ms %><span class="text-zinc-500 dark:text-zinc-400"><%= job.duration_ms %> ms</span><% end %>
      <% if job.output_truncated %><span class="text-zinc-400 dark:text-zinc-500">(truncated)</span><% end %>
    </div>

    <div class="p-3">
      <% if job.error.present? %>
        <p class="text-sm text-rose-600 dark:text-rose-400"><%= job.error %></p>
      <% elsif job.terminal? %>
        <% if job.stdout.present? %>
          <%= render "vulnerabilities/details/code_block", label: "stdout", content: job.stdout, language: nil, body_mime: false %>
        <% end %>
        <% if job.stderr.present? %>
          <div class="mt-2">
            <%= render "vulnerabilities/details/code_block", label: "stderr", content: job.stderr, language: nil, body_mime: false %>
          </div>
        <% end %>
      <% else %>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">Running…</p>
      <% end %>
    </div>
  </div>
<% end %>
```

Create `web/app/views/vulnerabilities/runs/create.turbo_stream.erb`:

```erb
<%= turbo_stream.replace "runner_run_#{@job.vulnerability_id}" do %>
  <%= render "vulnerabilities/runs/result", job: @job %>
<% end %>
```

Create `web/app/views/vulnerabilities/runs/show.html.erb`:

```erb
<%= render "vulnerabilities/runs/result", job: @job %>
```

Create `web/app/javascript/controllers/poller_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Reloads its host <turbo-frame> on an interval until the frame stops carrying
// this controller (terminal state). Cleans up its timer on disconnect.
export default class extends Controller {
  static values = { interval: { type: Number, default: 1500 } }

  connect() {
    this.timer = setInterval(() => {
      if (this.element.tagName === "TURBO-FRAME") this.element.reload()
    }, this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }
}
```

Edit `web/config/routes.rb` — inside `namespace :vulnerabilities`, add the two run routes **before** the catch-all `get "/:id"`:

```ruby
post "/:id/runs",          to: "runs#create", as: :runs
get  "/:id/runs/:job_id",  to: "runs#show",   as: :run
```

Edit `web/app/views/vulnerabilities/details/_panel.html.erb` — in the Proof of Concept section, next to the curl `code_block`, add a Run button and the result frame. Wrap so the button's Turbo Stream can replace the frame:

```erb
<div class="mt-3">
  <%= button_to vulnerabilities_runs_path(finding.id),
        class: "inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200" do %>
    <%= heroicon "play", classes: "h-3.5 w-3.5" %> Run curl
  <% end %>
  <div class="mt-3">
    <%= turbo_frame_tag "runner_run_#{finding.id}" %>
  </div>
</div>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/vulnerabilities/runs_test.rb`
Expected: PASS.

Notes:
- `Vulnerabilities::BaseController` supplies session auth (redirect when signed out) and the Department concern.
- Confirm `details/_code_block.html.erb` accepts `label`, `content`, `language`, `body_mime` locals; the existing panel already renders it with `language:`/`body_mime:`. If its local name for the body differs (e.g. `code:` instead of `content:`), match the existing call site — check `web/app/views/vulnerabilities/details/_panel.html.erb` before writing the `_result` partial and adjust the two `render "…/code_block"` calls accordingly.
- Add a `"play"` heroicon to `web/app/helpers/icon_helper.rb` if absent (grep first); if present, reuse it.

- [ ] **Step 5: Commit**

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/controllers/vulnerabilities/runs_controller.rb app/views/vulnerabilities/runs app/javascript/controllers/poller_controller.js app/views/vulnerabilities/details/_panel.html.erb app/helpers/icon_helper.rb config/routes.rb test/integration/vulnerabilities/runs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add curl run enqueue and self-polling result frame to the vuln drawer"
```

---

### Task 7: Runner container + agent

**Files:**
- Create: `runner/curl_command.rb` (identical `Sandbox::CurlCommand` copy)
- Create: `runner/agent.rb`
- Create: `runner/Dockerfile`
- Create: `runner/test/curl_command_test.rb`
- Modify: `docker-compose.yaml` (add hardened `runner` service)
- Modify: `.env.example` (add `RUNNER_TOKEN` + tuning vars)

**Interfaces:**
- Consumes: the Runner API (Task 5) over HTTP; `Sandbox::CurlCommand` (Task 1 logic, copied).
- Produces: a runnable container that claims curl jobs and posts results.

- [ ] **Step 1: Write the failing test (runner-side copy behaves identically)**

Create `runner/test/curl_command_test.rb`:

```ruby
require "minitest/autorun"
require_relative "../curl_command"

class RunnerCurlCommandTest < Minitest::Test
  def test_accepts_plain_https
    ok, argv = Sandbox::CurlCommand.validate("curl https://example.com")
    assert ok
    assert_equal %w[curl https://example.com], argv
  end

  def test_rejects_file_scheme
    ok, = Sandbox::CurlCommand.validate("curl file:///etc/passwd")
    refute ok
  end

  def test_rejects_output_flag
    ok, = Sandbox::CurlCommand.validate("curl -o /tmp/x https://example.com")
    refute ok
  end

  def test_execute_never_runs_invalid
    called = false
    Sandbox::CurlCommand.define_singleton_method(:capture) { |*| called = true; ["", "", 0] }
    r = Sandbox::CurlCommand.execute("curl file:///etc/passwd", max_time: 5, max_output: 100)
    refute called
    refute_nil r.error
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/claude/workspace/runner && ruby test/curl_command_test.rb`
Expected: FAIL — `curl_command.rb` missing.

- [ ] **Step 3: Copy the service and write the agent + Dockerfile**

Copy `web/app/services/sandbox/curl_command.rb` verbatim to `runner/curl_command.rb` (same `module Sandbox; module CurlCommand`). Keep the two files byte-identical; the runner test above is the guard that they stay in sync.

```bash
cp /home/claude/workspace/web/app/services/sandbox/curl_command.rb /home/claude/workspace/runner/curl_command.rb
```

Create `runner/agent.rb`:

```ruby
require "net/http"
require "json"
require "uri"
require_relative "curl_command"

# Minimal pull loop: claim a curl job, execute it in this hardened container,
# post the result back. Outbound HTTP only; never opens a listening socket.
API   = ENV.fetch("HUNTER_API_URL", "http://web:5000")
TOKEN = ENV.fetch("RUNNER_TOKEN")
POLL  = Float(ENV.fetch("RUNNER_POLL_INTERVAL", "2"))
MAX_TIME   = Integer(ENV.fetch("CURL_MAX_TIME", "30"))
MAX_OUTPUT = Integer(ENV.fetch("CURL_MAX_OUTPUT", "262144"))

def post(path, body = nil)
  uri = URI.join(API, path)
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  if body
    req["Content-Type"] = "application/json"
    req.body = body.to_json
  end
  Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 30) { |h| h.request(req) }
end

def claim
  res = post("/api/v1/runner/jobs/claim")
  return nil if res.code == "204"
  raise "claim failed: #{res.code}" unless res.code == "200"

  JSON.parse(res.body)
end

def submit(id, result)
  post("/api/v1/runner/jobs/#{id}/result", {
    exit_status: result.exit_status,
    stdout: result.stdout,
    stderr: result.stderr,
    error: result.error,
    duration_ms: result.duration_ms,
    output_truncated: result.output_truncated
  })
end

puts "runner agent starting; polling #{API} every #{POLL}s"
loop do
  begin
    job = claim
    if job.nil?
      sleep POLL
      next
    end
    result = Sandbox::CurlCommand.execute(job["command"], max_time: MAX_TIME, max_output: MAX_OUTPUT)
    submit(job["id"], result)
  rescue => e
    warn "runner error: #{e.class}: #{e.message}"
    sleep POLL * 3
  end
end
```

Create `runner/Dockerfile`:

```dockerfile
FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates ruby \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY runner/curl_command.rb runner/agent.rb ./

USER nobody
CMD ["ruby", "agent.rb"]
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /home/claude/workspace/runner && ruby test/curl_command_test.rb`
Expected: PASS.

Also syntax-check the agent: `ruby -c /home/claude/workspace/runner/agent.rb` → `Syntax OK`.

- [ ] **Step 5: Wire compose + env, then commit**

Edit `docker-compose.yaml` — add the hardened `runner` service (build context is the repo root so `runner/…` COPY paths resolve; **no `ports:`**):

```yaml
  runner:
    build:
      context: .
      dockerfile: runner/Dockerfile
    env_file: [.env]
    environment:
      HUNTER_API_URL: http://web:5000
      RUNNER_TOKEN: ${RUNNER_TOKEN}
      RUNNER_POLL_INTERVAL: ${RUNNER_POLL_INTERVAL:-2}
      CURL_MAX_TIME: ${CURL_MAX_TIME:-30}
      CURL_MAX_OUTPUT: ${CURL_MAX_OUTPUT:-262144}
    depends_on:
      web:
        condition: service_started
    user: "65534:65534"
    read_only: true
    tmpfs: ["/tmp"]
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 256m
    pids_limit: 128
    restart: unless-stopped
```

Edit `.env.example` — append:

```
# Runner (isolated curl execution)
RUNNER_TOKEN=
RUNNER_POLL_INTERVAL=2
CURL_MAX_TIME=30
CURL_MAX_OUTPUT=262144
RUNNER_JOB_TTL=90
```

Commit:

```bash
cd /home/claude/workspace && git -c user.name=Claude -c user.email=noreply@anthropic.com add runner docker-compose.yaml .env.example
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add hardened runner container and pull agent for curl execution"
```

---

## Self-Review

**Spec coverage:**
- RunnerJob (Postgres source of truth, uuid, kind allowlist, scoped atomic claim, staleness reaper) → Task 3. ✓
- Runner (scoped machine identity, digest-only token) → Task 2; rake mint → Task 4. ✓
- Runner API (`jobs/claim` scoped, `jobs/:id/result` with ownership check, runner-only auth) → Task 5. ✓
- Web enqueue + polling result + Run button + reaper-on-read → Task 6. ✓
- Safe execution (`Sandbox::CurlCommand` validate/execute, scheme allowlist, flag denylist, no shell, safety-flag injection, output caps) → Task 1 (web) + Task 7 (runner copy). ✓
- Runner container + agent + hardened compose service + env → Task 7. ✓
- Security guarantees (no host exec, no shell, http/https only, job-kind confinement, identity separation, no inbound ports) → covered across Tasks 1/3/5/7. ✓
- Error handling table (invalid curl, timeout, stuck job, missing vuln/poc, bad token, wrong-owner result, over-cap output) → asserted in Tasks 1/3/5/6. ✓

**Placeholder scan:** No TBD/TODO. Every code step shows full code. Two call-site checks are flagged as explicit verification steps (code_block locals, `play` heroicon) rather than placeholders, because they depend on existing files the implementer must read.

**Type consistency:** `Sandbox::CurlCommand` (not `Runner::CurlCommand`) used consistently in Tasks 1, 6, 7. `RunnerJob.claim!`, `record_result!`, `reap_if_stale!`, `reap_stale!`, `terminal?` signatures match between Task 3 definition and Tasks 4/5/6 callers. `Runner.generate/authenticate/digest` match between Task 2 and Tasks 4/5. `Result` struct fields match between Task 1 producer and Task 7 agent consumer. Frame id `runner_run_<vuln_id>` consistent between `_panel`, `_result`, and `create.turbo_stream`. Runner routes (`jobs/claim`, `jobs/:id/result`) consistent between Task 5 controller/routes and Task 7 agent.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-01-hunter-runner-curl-execution.md`. Two spec deviations are baked in (both to dodge Ruby constant collisions): the service is `Sandbox::CurlCommand`, and the rake namespace is `runners:`.
