require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::RunEventsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-ansible-run-events-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_run_events returns a bounded projection filtered by run_id, ordered by counter" do
    run = run_record
    other_run = run_record
    event(run, counter: 2, event_type: "runner_on_ok")
    event(run, counter: 1, event_type: "playbook_on_start")
    event(other_run, counter: 1, event_type: "runner_on_ok")

    get "/api/v1/assistant/machine/control_center/ansible/run_events",
      params: { run_id: run.id }, headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body["count"]
    counters = body["items"].map { |i| i["counter"] }
    assert_equal [ 1, 2 ], counters
    item = body["items"].first
    assert_equal %w[id counter event_uuid parent_uuid event_type play task host event_time stdout event_data truncated created_at],
      item.keys
  end

  test "list_run_events narrows by after_counter cursor" do
    run = run_record
    event(run, counter: 1, event_type: "a")
    event(run, counter: 2, event_type: "b")
    event(run, counter: 3, event_type: "c")

    get "/api/v1/assistant/machine/control_center/ansible/run_events",
      params: { run_id: run.id, after_counter: 1 }, headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body["count"]
    assert_equal [ 2, 3 ], body["items"].map { |i| i["counter"] }
  end

  test "list_run_events is not_found without a run_id param" do
    get "/api/v1/assistant/machine/control_center/ansible/run_events", headers: headers(read_grant)

    assert_response :not_found
  end

  test "list_run_events is refused without the control_center_ansible scope" do
    run = run_record
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/control_center/ansible/run_events",
      params: { run_id: run.id }, headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_granted", response.parsed_body["error"]
  end

  private

  def run_record
    group = ::ControlCenter::Ansible::RunGroup.create!(created_by: users(:one))
    group.runs.create!(
      position: 0,
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      playbook_name: "Baseline", inventory_name: "Workers", credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end

  def event(run, counter:, event_type:)
    run.run_events.create!(
      counter: counter, event_uuid: SecureRandom.uuid, event_type: event_type,
      stdout: "ok", event_data: {}
    )
  end

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_run_events" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
