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
