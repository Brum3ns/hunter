require "test_helper"

class ControlCenter::Ansible::SingleLaunchTest < ActiveSupport::TestCase
  PLAYBOOK_YAML = "---\n- hosts: workers\n  tasks: []\n"
  INVENTORY_YAML = "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.10.0.8\n"

  setup do
    @user = users(:one)
    @credential = ControlCenter::Ansible::Credential.create!(
      name: "Deploy", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", become_password: "sudo-secret", created_by: @user
    )
    @inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: INVENTORY_YAML,
      default_credential: @credential,
      known_hosts: "worker ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest",
      host_key_fingerprints: { "worker" => "SHA256:approved" },
      created_by: @user
    )
    @playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: PLAYBOOK_YAML, created_by: @user
    )
  end

  test "defines the single launch service" do
    assert defined?(ControlCenter::Ansible::SingleLaunch), "expected SingleLaunch to be defined"
  end

  test "creates one queued child with immutable snapshots and an encrypted payload" do
    variable_set = variable_set("Launch", "release", "2026.07", secret: false)
    secret_set = variable_set("Secrets", "deploy_token", "token-secret", secret: true)

    group = launch(
      variable_set_ids: [ variable_set.id, secret_set.id ],
      overrides: [
        { name: "port", value_type: "number", value: 8443, secret: false },
        { name: "ephemeral", value_type: "string", value: "override-secret", secret: true }
      ],
      host_limit: "workers:!retired", check_mode: true, timeout_seconds: 900
    )
    run = group.runs.sole

    assert_equal "queued", group.status
    assert_equal "queued", run.status
    assert_equal 0, run.position
    assert_equal @playbook.yaml_content, run.playbook_yaml
    assert_equal @inventory.yaml_content, run.inventory_yaml
    assert_equal @inventory.known_hosts, run.known_hosts
    assert_equal({ "release" => "2026.07", "port" => 8443 }, run.variable_audit)
    assert_equal [ "deploy_token", "ephemeral" ], run.secret_variable_names
    assert_equal "workers:!retired", run.host_limit
    assert run.check_mode
    assert_equal 900, run.timeout_seconds
    assert_in_delta 300, run.claim_deadline - run.queued_at, 2

    assert_equal [ variable_set.id, secret_set.id ], group.launch_snapshot.fetch("variable_set_ids")
    assert_equal [ "ephemeral" ], group.launch_snapshot.fetch("secret_override_names")
    assert_equal 8443, group.launch_snapshot.fetch("overrides").sole.fetch("value")
    refute_includes JSON.generate(group.launch_snapshot), "token-secret"
    refute_includes JSON.generate(group.launch_snapshot), "override-secret"

    assert_equal "fleet-secret", group.execution_payload.dig("secrets", "ssh_password")
    assert_equal "token-secret", group.execution_payload.dig("variables", "deploy_token")
    assert_equal "override-secret", group.execution_payload.dig("variables", "ephemeral")

    raw_payload = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT execution_payload FROM control_center_ansible_run_groups WHERE id = #{group.id.to_i}
    SQL
    refute_includes raw_payload, "fleet-secret"
    refute_includes raw_payload, "token-secret"
    refute_includes JSON.generate(run.attributes), "fleet-secret"
    refute_includes JSON.generate(run.attributes), "token-secret"
  end

  test "source edits and credential rotation do not change launched data" do
    group = launch
    original_payload = Marshal.load(Marshal.dump(group.execution_payload))
    original_run = group.runs.sole.attributes.slice("playbook_yaml", "inventory_yaml", "known_hosts")

    @playbook.update!(yaml_content: "---\n- hosts: changed\n  tasks: []\n")
    @inventory.update!(yaml_content: "---\nchanged: {}\n", known_hosts: "changed ssh-ed25519 AAAA")
    @credential.update!(ssh_password: "rotated-secret")

    assert_equal original_payload, group.reload.execution_payload
    assert_equal original_run, group.runs.sole.reload.attributes.slice(*original_run.keys)
  end

  test "rejects a missing or unusable credential" do
    @inventory.update!(default_credential: nil)

    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch(credential_id: 99_999) }
    assert_includes error.details.fetch(:credential_id), "was not found"

    @inventory.update!(default_credential: @credential)
    @credential.update_columns(ssh_password: nil)
    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch }
    assert_includes error.details.fetch(:credential_id), "does not have a usable password"
  end

  test "rejects inventory without approved host keys" do
    @inventory.update!(known_hosts: nil, host_key_fingerprints: {})

    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch }

    assert_includes error.details.fetch(:inventory_id), "must have approved host keys"
  end

  test "rejects invalid variable resolution" do
    first = variable_set("First", "release", "one", secret: false)
    second = variable_set("Second", "release", "two", secret: false)

    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) do
      launch(variable_set_ids: [ first.id, second.id ])
    end

    assert_includes error.details.fetch(:variables), 'duplicate variable "release" at launch level'
  end

  test "rejects unsafe host limits and timeout bounds" do
    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch(host_limit: "@/tmp/hosts") }
    assert_includes error.details.fetch(:host_limit), "contains unsupported characters"

    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch(timeout_seconds: 59) }
    assert_includes error.details.fetch(:timeout_seconds), "must be between 60 and 86400"
  end

  test "revalidates saved YAML before creating history" do
    @playbook.update_columns(yaml_content: "---\nnot: a playbook\n")

    error = assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch }

    assert error.details.fetch(:playbook_id).any? { |message| message.include?("non-empty array") }
    assert_no_difference -> { ControlCenter::Ansible::RunGroup.count } do
      assert_raises(ControlCenter::Ansible::SingleLaunch::Error) { launch }
    end
  end

  test "rolls the group back when child persistence fails" do
    failure = ->(*) { raise ActiveRecord::RecordInvalid.new(ControlCenter::Ansible::Run.new) }

    assert_no_difference -> { ControlCenter::Ansible::RunGroup.count } do
      stub_methods(ControlCenter::Ansible::Run, create!: failure) do
        assert_raises(ActiveRecord::RecordInvalid) { launch }
      end
    end
  end

  private

  def launch(**overrides)
    ControlCenter::Ansible::SingleLaunch.call(**{
      user: @user,
      playbook_id: @playbook.id,
      inventory_id: @inventory.id,
      credential_id: nil,
      variable_set_ids: [],
      overrides: [],
      host_limit: nil,
      check_mode: false,
      timeout_seconds: 3600
    }.merge(overrides))
  end

  def variable_set(name, variable_name, value, secret:)
    set = ControlCenter::Ansible::VariableSet.create!(name:, created_by: @user)
    set.variables.create!(
      name: variable_name,
      value_type: "string",
      serialized_value: JSON.generate(value),
      secret:
    )
    set
  end
end
