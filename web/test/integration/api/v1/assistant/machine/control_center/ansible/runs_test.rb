require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::RunsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-ansible-runs-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "get_run returns the full projection, excluding secret snapshot fields" do
    record = run_record(
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      lease_digest: "digest-secret",
      runner_id: nil,
      credential_fingerprint: "SHA256:abc",
      variable_audit: { "port" => 22 },
      secret_variable_names: [ "deploy_token" ],
      status: "succeeded", exit_status: 0
    )

    get "/api/v1/assistant/machine/control_center/ansible/runs/#{record.id}", headers: headers

    assert_response :success
    result = response.parsed_body["run"]
    expected_keys = %w[
      id run_group_id playbook_id position status playbook_name inventory_name credential_name
      credential_fingerprint variable_audit secret_variable_names host_limit check_mode timeout_seconds
      error_code error_detail exit_status ok_count changed_count failed_count unreachable_count
      stored_event_bytes truncated queued_at started_at completed_at cancel_requested_at created_at updated_at
    ]
    assert_equal expected_keys, result.keys
    assert_equal "succeeded", result["status"]
    assert_equal({ "port" => 22 }, result["variable_audit"])
    assert_equal [ "deploy_token" ], result["secret_variable_names"]

    %w[playbook_yaml inventory_yaml known_hosts lease_digest runner_id].each do |forbidden|
      refute result.key?(forbidden), "expected #{forbidden} to be excluded from the projection"
    end
    refute_match(/digest-secret/, response.body)
    refute_match(/hosts: workers/, response.body)
  end

  test "get_run is refused when its live capability is disabled" do
    record = run_record
    Assistant::Setting.instance.update!(disabled_capability_tools: [ "get_run" ])

    get "/api/v1/assistant/machine/control_center/ansible/runs/#{record.id}", headers: headers

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  test "get_run releases the reservation on a miss" do
    get "/api/v1/assistant/machine/control_center/ansible/runs/999999999", headers: headers

    assert_response :not_found
  end

  private

  def run_record(status: "queued", exit_status: nil, playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
          inventory_yaml: "---\nall:\n  hosts:\n    worker:\n", known_hosts: "worker ssh-ed25519 AAAA",
          lease_digest: nil, runner_id: nil, credential_fingerprint: nil,
          variable_audit: {}, secret_variable_names: [])
    group = ::ControlCenter::Ansible::RunGroup.create!(created_by: users(:one))
    group.runs.create!(
      position: 0, status: status, exit_status: exit_status,
      playbook_yaml: playbook_yaml, inventory_yaml: inventory_yaml, known_hosts: known_hosts,
      playbook_name: "Baseline", inventory_name: "Workers", credential_name: "Deploy",
      credential_fingerprint: credential_fingerprint, timeout_seconds: 3600,
      variable_audit: variable_audit, secret_variable_names: secret_variable_names
    ).tap do |record|
      record.update_columns(lease_digest: lease_digest, runner_id: runner_id) if lease_digest || runner_id
    end
  end

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
