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

  test "reap_stale! reaps all running jobs past the TTL" do
    job = queue
    RunnerJob.claim!(@curl_runner)
    job.reload.update_column(:started_at, 1.hour.ago)
    count = RunnerJob.reap_stale!
    assert_equal 1, count
    assert_equal "failed", job.reload.status
    assert_match(/timed out/i, job.error)
  end

  test "terminal? is true only for succeeded/failed" do
    job = queue
    refute job.terminal?
    job.update_column(:status, "succeeded")
    assert job.terminal?
  end
end
