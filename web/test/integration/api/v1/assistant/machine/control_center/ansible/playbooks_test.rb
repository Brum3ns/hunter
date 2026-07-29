require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::PlaybooksTest < ActionDispatch::IntegrationTest
  YAML_CONTENT = "---\n- hosts: workers\n  tasks: []\n"

  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-ansible-playbooks-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_playbooks returns a bounded projection ordered by lower(name)" do
    playbook(name: "Zeta")
    playbook(name: "alpha")

    get "/api/v1/assistant/machine/control_center/ansible/playbooks", headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body["count"]
    names = body["items"].map { |i| i["name"] }
    assert_equal %w[alpha Zeta], names
    item = body["items"].first
    assert_equal %w[id name description checksum updated_at], item.keys
  end

  test "list_playbooks is refused without the control_center_ansible scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/control_center/ansible/playbooks", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
  end

  test "get_playbook returns the full projection" do
    record = playbook(name: "Baseline", description: "d")

    get "/api/v1/assistant/machine/control_center/ansible/playbooks/#{record.id}", headers: headers(read_grant)

    assert_response :success
    result = response.parsed_body["playbook"]
    expected_keys = %w[id name description checksum updated_at yaml_content variable_set_ids created_at]
    assert_equal expected_keys, result.keys
    assert_equal "Baseline", result["name"]
    assert_equal YAML_CONTENT, result["yaml_content"]
    assert_equal [], result["variable_set_ids"]
  end

  test "get_playbook releases the reservation on a miss" do
    get "/api/v1/assistant/machine/control_center/ansible/playbooks/999999999", headers: headers(read_grant)

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def playbook(name:, description: nil)
    ::ControlCenter::Ansible::Playbook.create!(
      name: name, description: description, yaml_content: YAML_CONTENT, created_by: users(:one)
    )
  end

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_playbooks", "get_playbook" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
