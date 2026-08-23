require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::PlaybooksCreateTest < ActionDispatch::IntegrationTest
  VALID_YAML = <<~YAML
    ---
    - name: Explain selection
      hosts: workers
      gather_facts: false
      tasks:
        - name: Report
          ansible.builtin.debug:
            msg: ready
  YAML

  SHELL_YAML = <<~YAML
    ---
    - hosts: workers
      tasks:
        - name: Run it
          ansible.builtin.shell: rm -rf /
  YAML

  URL_YAML = <<~YAML
    ---
    - hosts: workers
      tasks:
        - name: Fetch
          ansible.builtin.debug:
            msg: "http://example.com/payload"
  YAML

  VALID_PLAYBOOK = { name: "assistant-playbook", source: VALID_YAML }.freeze

  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.enable_control_center_write!
    @original_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-ansible-playbooks-create-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_allowlist
  end

  test "creates a valid playbook using only an allowlisted module" do
    post "/api/v1/assistant/machine/control_center/ansible/playbooks",
      params: { playbook: VALID_PLAYBOOK }, headers: headers(write_grant), as: :json

    assert_response :created
    body = response.parsed_body
    assert body["correlation_id"].present?
    receipt = body.fetch("receipt")
    assert_equal "created", receipt.fetch("status")
    assert_equal "ansible_playbook", receipt.dig("target", "type")

    record = ::ControlCenter::Ansible::Playbook.find(receipt.dig("target", "id"))
    assert_equal "assistant-playbook", record.name
    assert_equal VALID_YAML, record.yaml_content
    assert_equal machine_user, record.created_by

    event = Assistant::AuditEvent.where(event: "machine.create").order(:id).last
    assert_equal "machine.create", event.event
    assert_equal "create_ansible_playbook", event.metadata["operation"]
  end

  test "creates an exact maximum-size source including its JSON envelope" do
    source = VALID_YAML + "# " + ("<" * (Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES - VALID_YAML.bytesize - 2))
    assert_equal Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES, source.bytesize

    post "/api/v1/assistant/machine/control_center/ansible/playbooks",
      params: { playbook: { name: "maximum-source", source: source } },
      headers: headers(write_grant), as: :json

    assert_response :created
    record = ControlCenter::Ansible::Playbook.find(response.parsed_body.dig("receipt", "target", "id"))
    assert_equal source, record.yaml_content
  end

  test "rejects a playbook using ansible.builtin.shell and persists nothing" do
    assert_no_difference -> { ::ControlCenter::Ansible::Playbook.count } do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks",
        params: { playbook: { name: "assistant-playbook", source: SHELL_YAML } },
        headers: headers(write_grant), as: :json
    end

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body["error"]
    assert_includes response.parsed_body["codes"], "ansible_module_not_allowed"
  end

  test "rejects a playbook containing a URL and persists nothing" do
    assert_no_difference -> { ::ControlCenter::Ansible::Playbook.count } do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks",
        params: { playbook: { name: "assistant-playbook", source: URL_YAML } },
        headers: headers(write_grant), as: :json
    end

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body["error"]
    assert_includes response.parsed_body["codes"], "ansible_url_not_allowed"
  end

  test "returns a stable validation code for an unknown variable set" do
    grant = write_grant
    grant_record = Assistant::TurnGrant.order(:id).last

    assert_no_difference -> { ::ControlCenter::Ansible::Playbook.count } do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks",
        params: { playbook: VALID_PLAYBOOK.merge(variable_set_ids: [ 9_999_999 ]) },
        headers: headers(grant), as: :json
    end

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body["error"]
    assert_equal [ "ansible_variable_set_ids_unknown" ], response.parsed_body["codes"]
    assert_equal 0, grant_record.reload.reserved_bytes
  end

  test "refuses a grant without the write scope" do
    grant = write_grant
    Assistant::TurnGrant.order(:id).last.update_column(:write_scopes, [])

    assert_no_difference -> { ::ControlCenter::Ansible::Playbook.count } do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks",
        params: { playbook: VALID_PLAYBOOK }, headers: headers(grant), as: :json
    end

    assert_response :forbidden
    assert_equal "scope_not_granted", response.parsed_body["error"]
  end

  test "refuses to create when the control center write toggle is off" do
    grant = write_grant
    Assistant::Setting.instance.disable_control_center_write!(user: machine_user)

    assert_no_difference -> { ::ControlCenter::Ansible::Playbook.count } do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks",
        params: { playbook: VALID_PLAYBOOK }, headers: headers(grant), as: :json
    end

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  private

  def machine_user
    assistant_turns(:created).user
  end

  def write_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "create_ansible_playbook" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
