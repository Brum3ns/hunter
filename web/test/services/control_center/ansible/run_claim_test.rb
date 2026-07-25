require "test_helper"

class ControlCenter::Ansible::RunClaimTest < ActiveSupport::TestCase
  test "defines the atomic run claim service" do
    assert defined?(ControlCenter::Ansible::RunClaim), "expected RunClaim to be defined"
  end

  test "claims the oldest eligible run and returns its payload exactly once" do
    newer = create_run(queued_at: 1.minute.ago, payload: { "secret" => "newer" })
    older = create_run(queued_at: 2.minutes.ago, payload: { "secret" => "older" })
    runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    now = Time.current

    claim = ControlCenter::Ansible::RunClaim.call(runner:, now:)

    assert_equal older.id, claim.run.id
    assert_equal({ "secret" => "older" }, claim.payload)
    assert claim.lease.present?
    refute_equal claim.lease, older.reload.lease_digest
    assert_equal Digest::SHA256.hexdigest(claim.lease), older.lease_digest
    assert_equal "validating", older.status
    assert_equal runner, older.runner
    assert_in_delta 45, older.lease_expires_at - now, 1
    assert_equal "running", older.run_group.reload.status

    second = ControlCenter::Ansible::RunClaim.call(runner:, now:)
    assert_equal newer.id, second.run.id
    assert_nil ControlCenter::Ansible::RunClaim.call(runner:, now:)
  end

  test "skips expired and cancellation-requested queued work" do
    expired = create_run(queued_at: 3.minutes.ago, claim_deadline: 1.second.ago)
    canceled_group_run = create_run(queued_at: 2.minutes.ago)
    canceled_group_run.run_group.update_columns(cancel_requested_at: Time.current)
    eligible = create_run(queued_at: 1.minute.ago)
    runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])

    claim = ControlCenter::Ansible::RunClaim.call(runner:, now: Time.current)

    assert_equal eligible.id, claim.run.id
    assert_equal "queued", expired.reload.status
    assert_equal "queued", canceled_group_run.reload.status
  end

  private

  def create_run(queued_at:, payload: { "secret" => "value" }, claim_deadline: 5.minutes.from_now)
    group = ControlCenter::Ansible::RunGroup.create!(
      created_by: users(:one), execution_payload: payload,
      launch_snapshot: { "playbook" => { "name" => "Baseline" } }
    )
    group.runs.create!(
      position: 0,
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600,
      queued_at:,
      claim_deadline:
    )
  end
end
