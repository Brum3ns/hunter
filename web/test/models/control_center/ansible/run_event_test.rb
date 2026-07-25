require "test_helper"

class ControlCenter::Ansible::RunEventTest < ActiveSupport::TestCase
  test "defines the run event model" do
    assert defined?(ControlCenter::Ansible::RunEvent), "expected RunEvent to be defined"
  end

  test "event UUID and counter are unique within one run" do
    run = create_run
    run.run_events.create!(event_uuid: "uuid-1", counter: 1, event_type: "runner_on_ok")

    duplicate_uuid = run.run_events.build(event_uuid: "uuid-1", counter: 2, event_type: "runner_on_failed")
    duplicate_counter = run.run_events.build(event_uuid: "uuid-2", counter: 1, event_type: "runner_on_failed")

    refute duplicate_uuid.valid?
    assert_includes duplicate_uuid.errors[:event_uuid], "has already been taken"
    refute duplicate_counter.valid?
    assert_includes duplicate_counter.errors[:counter], "has already been taken"
  end

  test "the same UUID and counter may be used by different runs" do
    first = create_run(position: 0)
    second = create_run(position: 1)
    first.run_events.create!(event_uuid: "uuid-1", counter: 1, event_type: "runner_on_ok")

    event = second.run_events.build(event_uuid: "uuid-1", counter: 1, event_type: "runner_on_ok")

    assert event.valid?
  end

  private

  def create_run(position: 0)
    group = ControlCenter::Ansible::RunGroup.create!(created_by: users(:one))
    group.runs.create!(
      position:,
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end
end
