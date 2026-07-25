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

  test "destroying a runner nullifies its jobs but keeps them" do
    runner, = Runner.generate(name: "curl-runner", kinds: %w[curl])
    user = users(:one)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "v",
                            requested_by: user, status: "running", runner: runner, started_at: Time.current)
    runner.destroy
    assert RunnerJob.exists?(job.id), "job should survive runner deletion"
    assert_nil job.reload.runner_id
  end

  test "kinds must be present" do
    assert_raises(ActiveRecord::RecordInvalid) { Runner.generate(name: "empty", kinds: []) }
  end

  test "accepts ansible and rejects unknown capabilities" do
    runner, = Runner.generate(name: "ansible-executor", kinds: %w[ansible])
    assert_equal %w[ansible], runner.kinds

    assert_raises(ActiveRecord::RecordInvalid) do
      Runner.generate(name: "unsafe", kinds: %w[shell])
    end
  end

  test "normalizes capability values before validation" do
    runner, = Runner.generate(name: "mixed", kinds: [ " curl ", "", "curl", :ansible ])
    assert_equal %w[curl ansible], runner.kinds
  end

  test "ensure_from_token! registers a runner that authenticates with the given token" do
    token = SecureRandom.urlsafe_base64(32)
    runner = Runner.ensure_from_token!(name: "env-runner", token: token, kinds: %w[curl])

    assert runner.persisted?
    assert_equal %w[curl], runner.kinds
    assert_equal runner.id, Runner.authenticate(token).id
    assert_not_equal token, runner.token_digest, "raw token must never be stored"
  end

  test "ensure_from_token! is idempotent on name and rotates the token in place" do
    old_token = SecureRandom.urlsafe_base64(32)
    new_token = SecureRandom.urlsafe_base64(32)

    first = Runner.ensure_from_token!(name: "env-runner", token: old_token, kinds: %w[curl])
    second = Runner.ensure_from_token!(name: "env-runner", token: new_token, kinds: %w[curl])

    assert_equal first.id, second.id, "same name must update the same row, not orphan a new one"
    assert_equal 1, Runner.where(name: "env-runner").count
    assert_equal second.id, Runner.authenticate(new_token).id
    assert_nil Runner.authenticate(old_token), "the rotated-out token must stop working"
  end

  test "ensure_from_token! normalizes surrounding quotes and whitespace" do
    token = SecureRandom.urlsafe_base64(32)
    runner = Runner.ensure_from_token!(name: "env-runner", token: %(  "#{token}"  ), kinds: %w[curl])

    assert_equal runner.id, Runner.authenticate(token).id,
                 "a quoted/padded env value must digest to the same token the runner sends"
  end

  test "ensure_from_token! skips a blank token without creating a runner" do
    assert_nil Runner.ensure_from_token!(name: "env-runner", token: "", kinds: %w[curl])
    assert_nil Runner.ensure_from_token!(name: "env-runner", token: nil, kinds: %w[curl])
    assert_nil Runner.ensure_from_token!(name: "env-runner", token: %(  ), kinds: %w[curl])
    assert_equal 0, Runner.where(name: "env-runner").count
  end

  test "ensure_from_token! rejects a weak token and creates nothing" do
    weak = "a" * (Runner::MINIMUM_TOKEN_LENGTH - 1)
    assert_raises(Runner::WeakTokenError) do
      Runner.ensure_from_token!(name: "env-runner", token: weak, kinds: %w[curl])
    end
    assert_equal 0, Runner.where(name: "env-runner").count
  end
end
