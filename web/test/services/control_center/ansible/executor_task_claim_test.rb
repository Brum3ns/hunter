require "test_helper"

class ControlCenter::Ansible::ExecutorTaskClaimTest < ActiveSupport::TestCase
  test "defines the atomic utility-task claim service" do
    assert defined?(ControlCenter::Ansible::ExecutorTaskClaim), "expected ExecutorTaskClaim to be defined"
  end

  test "claims oldest eligible utility work with a digest-only lease" do
    newer = create_task(created_at: 1.minute.ago, payload: { "yaml" => "newer" })
    older = create_task(created_at: 2.minutes.ago, payload: { "yaml" => "older" })
    runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    now = Time.current

    claim = ControlCenter::Ansible::ExecutorTaskClaim.call(runner:, now:)

    assert_equal older.id, claim.task.id
    assert_equal({ "yaml" => "older" }, claim.payload)
    assert_equal Digest::SHA256.hexdigest(claim.lease), older.reload.lease_digest
    assert_equal "running", older.status
    assert_equal runner, older.runner
    assert_in_delta 45, older.lease_expires_at - now, 1
    assert_equal newer.id, ControlCenter::Ansible::ExecutorTaskClaim.call(runner:, now:).task.id
    assert_nil ControlCenter::Ansible::ExecutorTaskClaim.call(runner:, now:)
  end

  test "does not claim expired utility work" do
    create_task(created_at: 1.minute.ago, claim_deadline: 1.second.ago)
    runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])

    assert_nil ControlCenter::Ansible::ExecutorTaskClaim.call(runner:, now: Time.current)
  end

  private

  def create_task(created_at:, payload: { "yaml" => "value" }, claim_deadline: 5.minutes.from_now)
    ControlCenter::Ansible::ExecutorTask.create!(
      kind: "syntax_check",
      created_by: users(:one),
      execution_payload: payload,
      claim_deadline:,
      created_at:
    )
  end
end
