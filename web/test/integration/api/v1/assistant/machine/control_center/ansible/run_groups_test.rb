require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::RunGroupsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-ansible-run-groups-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "list_run_groups returns a bounded projection ordered by created_at desc" do
    older = run_group(created_at: 2.hours.ago)
    newer = run_group(created_at: 1.hour.ago)

    get "/api/v1/assistant/machine/control_center/ansible/run_groups", headers: headers

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body["count"]
    ids = body["items"].map { |i| i["id"] }
    assert_equal [ newer.id, older.id ], ids
    item = body["items"].first
    assert_equal %w[id status execution_mode failure_policy inventory_id credential_id started_at completed_at created_at],
      item.keys
  end

  test "list_run_groups is refused when its live capability is disabled" do
    Assistant::Setting.instance.update!(disabled_capability_tools: [ "list_run_groups" ])

    get "/api/v1/assistant/machine/control_center/ansible/run_groups", headers: headers

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  test "get_run_group returns the full projection with child run summaries, never execution_payload" do
    group = run_group(execution_payload: { "secrets" => { "ssh_password" => "fleet-secret" } })
    run = create_run(group: group, position: 0, playbook_name: "Baseline", status: "succeeded", exit_status: 0)

    get "/api/v1/assistant/machine/control_center/ansible/run_groups/#{group.id}", headers: headers

    assert_response :success
    result = response.parsed_body["run_group"]
    expected_keys = %w[
      id status execution_mode failure_policy inventory_id credential_id started_at completed_at created_at
      concurrency_limit launch_snapshot cancel_requested_at updated_at runs
    ]
    assert_equal expected_keys, result.keys
    refute result.key?("execution_payload")
    refute_match(/fleet-secret/, response.body)
    refute_match(/execution_payload/, response.body)

    assert_equal 1, result["runs"].length
    run_item = result["runs"].first
    assert_equal %w[id position status playbook_name exit_status], run_item.keys
    assert_equal run.id, run_item["id"]
    assert_equal "Baseline", run_item["playbook_name"]
  end

  test "get_run_group releases the reservation on a miss" do
    get "/api/v1/assistant/machine/control_center/ansible/run_groups/999999999", headers: headers

    assert_response :not_found
  end

  private

  def run_group(created_at: Time.current, execution_payload: nil)
    ::ControlCenter::Ansible::RunGroup.create!(created_by: users(:one), execution_payload: execution_payload).tap do |group|
      group.update_column(:created_at, created_at)
    end
  end

  def create_run(group:, position:, playbook_name:, status: "queued", exit_status: nil)
    group.runs.create!(
      position: position,
      status: status,
      exit_status: exit_status,
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      playbook_name: playbook_name,
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
