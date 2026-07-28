require "test_helper"

class ControlCenter::Ansible::RunGroupTest < ActiveSupport::TestCase
  test "defines the execution group model" do
    assert defined?(ControlCenter::Ansible::RunGroup), "expected RunGroup to be defined"
  end

  test "validates status mode failure policy and concurrency" do
    group = build_group(
      status: "unknown",
      execution_mode: "serial-ish",
      failure_policy: "ignore",
      concurrency_limit: 0
    )

    refute group.valid?
    assert group.errors[:status].any?
    assert group.errors[:execution_mode].any?
    assert group.errors[:failure_policy].any?
    assert group.errors[:concurrency_limit].any?
  end

  test "orders child runs by position then id" do
    group = build_group
    group.save!
    later = create_run(group:, position: 2, playbook_name: "Later")
    earlier = create_run(group:, position: 1, playbook_name: "Earlier")

    assert_equal [ earlier, later ], group.reload.runs.to_a
  end

  test "encrypts the ephemeral execution payload in the database" do
    group = build_group(execution_payload: { "secrets" => { "ssh_password" => "fleet-secret" } })
    group.save!

    raw = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT execution_payload
      FROM control_center_ansible_run_groups
      WHERE id = #{group.id.to_i}
    SQL

    refute_includes raw, "fleet-secret"
    assert_equal "fleet-secret", group.reload.execution_payload.dig("secrets", "ssh_password")
  end

  test "launch snapshot is immutable after persistence" do
    group = build_group(launch_snapshot: { "playbook_id" => 1 })
    group.save!

    refute group.update(launch_snapshot: { "playbook_id" => 2 })
    assert_includes group.errors[:launch_snapshot], "cannot be changed after launch"
  end

  test "terminal predicate uses explicit terminal statuses" do
    %w[succeeded failed partially_succeeded canceled].each do |status|
      assert build_group(status:).terminal?, "expected #{status} to be terminal"
    end
    %w[queued running canceling].each do |status|
      refute build_group(status:).terminal?, "expected #{status} not to be terminal"
    end
  end

  private

  def build_group(attributes = {})
    ControlCenter::Ansible::RunGroup.new({
      created_by: users(:one),
      launch_snapshot: { "playbook_id" => 1 }
    }.merge(attributes))
  end

  def create_run(group:, position:, playbook_name:)
    ControlCenter::Ansible::Run.create!(
      run_group: group,
      position:,
      status: "queued",
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      playbook_name:,
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end
end
