require "test_helper"

class ControlCenter::Ansible::RunCancellationTest < ActiveSupport::TestCase
  test "queued group cancellation is immediately terminal and purges payload" do
    group, run = create_group(status: "queued")

    result = ControlCenter::Ansible::RunCancellation.cancel_group!(group)

    assert_equal "canceled", result.status
    assert_nil result.execution_payload
    assert result.completed_at
    assert_equal "canceled", run.reload.status
  end

  test "active cancellation is idempotently requested" do
    group, run = create_group(status: "running")

    first = ControlCenter::Ansible::RunCancellation.cancel_run!(run)
    requested_at = first.cancel_requested_at
    second = ControlCenter::Ansible::RunCancellation.cancel_run!(first)

    assert_equal "canceling", second.status
    assert_equal requested_at, second.cancel_requested_at
    assert_equal "canceling", group.reload.status
    assert group.execution_payload
  end

  private

  def create_group(status:)
    group = ControlCenter::Ansible::RunGroup.create!(
      created_by: users(:one), status: status == "queued" ? "queued" : "running",
      execution_payload: { "secret" => "value" }
    )
    run = group.runs.create!(
      position: 0,
      status:,
      playbook_yaml: "--- playbook",
      inventory_yaml: "--- inventory",
      known_hosts: "known hosts",
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
    [ group, run ]
  end
end
