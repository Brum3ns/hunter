require "test_helper"

class ControlCenter::Ansible::RunReaperTest < ActiveSupport::TestCase
  test "defines stale-work reaping" do
    assert defined?(ControlCenter::Ansible::RunReaper), "expected RunReaper to be defined"
  end

  test "fails expired queued and leased runs without requeueing and purges payloads" do
    now = Time.current
    queued = create_run(status: "queued", claim_deadline: 1.second.ago, lease_expires_at: nil)
    active = create_run(status: "running", claim_deadline: 5.minutes.from_now, lease_expires_at: 1.second.ago)

    result = ControlCenter::Ansible::RunReaper.call(now:)

    assert_equal 2, result.runs
    assert_equal "failed", queued.reload.status
    assert_equal "executor_unavailable", queued.error_code
    assert_nil queued.run_group.reload.execution_payload
    assert_equal "failed", active.reload.status
    assert_equal "executor_lost", active.error_code
    assert_nil active.lease_digest
    assert_nil active.run_group.reload.execution_payload
  end

  test "fails expired utility tasks and retains fresh work" do
    stale = create_task(status: "running", lease_expires_at: 1.second.ago)
    fresh = create_task(status: "queued", lease_expires_at: nil, claim_deadline: 5.minutes.from_now)

    result = ControlCenter::Ansible::RunReaper.call(now: Time.current)

    assert_equal 1, result.tasks
    assert_equal "failed", stale.reload.status
    assert_equal "executor_lost", stale.error_code
    assert_nil stale.execution_payload
    assert_equal "queued", fresh.reload.status
    assert fresh.execution_payload
  end

  private

  def create_run(status:, claim_deadline:, lease_expires_at:)
    runner = if status == "queued"
      nil
    else
      Runner.generate(name: "ansible-#{SecureRandom.hex(3)}", kinds: [ "ansible" ]).first
    end
    group = ControlCenter::Ansible::RunGroup.create!(
      created_by: users(:one), status: status == "queued" ? "queued" : "running",
      execution_payload: { "secret" => "value" }
    )
    group.runs.create!(
      position: 0,
      status:,
      runner:,
      lease_digest: runner ? Digest::SHA256.hexdigest("lease") : nil,
      lease_expires_at:,
      claim_deadline:,
      playbook_yaml: "--- playbook",
      inventory_yaml: "--- inventory",
      known_hosts: "known hosts",
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end

  def create_task(status:, lease_expires_at:, claim_deadline: 1.second.ago)
    runner = if status == "queued"
      nil
    else
      Runner.generate(name: "task-#{SecureRandom.hex(3)}", kinds: [ "ansible" ]).first
    end
    ControlCenter::Ansible::ExecutorTask.create!(
      kind: "syntax_check",
      status:,
      created_by: users(:one),
      execution_payload: { "secret" => "value" },
      runner:,
      lease_digest: runner ? Digest::SHA256.hexdigest("lease") : nil,
      lease_expires_at:,
      claim_deadline:
    )
  end
end
