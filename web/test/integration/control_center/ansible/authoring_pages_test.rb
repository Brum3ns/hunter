require "test_helper"

class ControlCenter::Ansible::AuthoringPagesTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "playbooks page mounts an accessible authoring shell with public configuration only" do
    create_stored_secrets
    get control_center_ansible_root_path

    assert_response :success
    assert_authoring_shell(
      index_url: api_v1_control_center_ansible_playbooks_path,
      validate_url: validate_api_v1_control_center_ansible_playbooks_path,
      resource_type: "playbook"
    )
    assert_select "input[type=file][multiple]", count: 1
    assert_select "button", text: /Download selected/
    refute_includes response.body, "credential-secret"
    refute_includes response.body, "variable-secret"
  end

  test "playbooks page mounts selection controls for visible rows and ZIP export" do
    get control_center_ansible_root_path

    assert_response :success
    assert_select "section[data-controller~='ansible-playbook-selection']" \
                  "[data-ansible-playbook-selection-export-url-value=?]",
                  export_api_v1_control_center_ansible_playbooks_path
    assert_select "input[type=checkbox][data-ansible-playbook-selection-target=selectAll]" \
                  "[data-action='ansible-playbook-selection#toggleVisible']"
    assert_select "button[disabled][data-ansible-playbook-selection-target=download]" \
                  "[data-action='ansible-playbook-selection#download']", text: /Download selected/
    assert_select "[aria-live=polite][data-ansible-playbook-selection-target=status]"
  end

  test "inventories page mounts its editor and endpoint values" do
    get control_center_ansible_inventories_path

    assert_response :success
    assert_authoring_shell(
      index_url: api_v1_control_center_ansible_inventories_path,
      validate_url: validate_api_v1_control_center_ansible_inventories_path,
      resource_type: "inventory"
    )
    assert_select "section[data-controller=ansible-inventory-tools]" \
                  "[data-ansible-inventory-tools-index-url-value=?]",
                  api_v1_control_center_ansible_inventories_path
    assert_select "button[disabled][data-ansible-inventory-tools-target=scanButton]", text: /Scan host keys/
    assert_select "button[disabled][data-ansible-inventory-tools-target=connectButton]", text: /Test connectivity/
    assert_select "[data-ansible-inventory-tools-target=candidates]", text: /untrusted/i
    assert_select "template[data-ansible-inventory-tools-target=candidateTemplate] input[data-field=expected-fingerprint]"
    assert_select "[data-ansible-inventory-tools-target=storedFingerprints]"
  end

  test "variable sets page renders ordered typed write-only variable rows" do
    get control_center_ansible_variable_sets_path

    assert_response :success
    assert_select "section[data-controller~=ansible-variable-sets]" \
                  "[data-ansible-variable-sets-index-url-value=?]",
                  api_v1_control_center_ansible_variable_sets_path
    assert_select "template[data-ansible-variable-sets-target=variableTemplate]" do
      assert_select "input[data-field=name]"
      assert_select "select[data-field=value-type] option", count: 5
      assert_select "input[type=checkbox][data-field=secret]"
      assert_select "input[data-field=value][autocomplete=off]"
      assert_select "button[aria-label='Move variable up']"
      assert_select "button[aria-label='Move variable down']"
      assert_select "button[aria-label='Delete variable']"
    end
  end

  test "runs page renders the execution history surface" do
    get control_center_ansible_runs_path

    assert_response :success
    assert_select "h2", text: "Run history"
    assert_select "[data-run-history]"
    assert_select "[data-executor-guidance]", text: /executor/i
    refute_match "Execution is not enabled yet", response.body
  end

  private

  def assert_authoring_shell(index_url:, validate_url:, resource_type:)
    selector = "section[data-controller~=ansible-authoring]" \
      "[data-ansible-authoring-index-url-value='#{index_url}']" \
      "[data-ansible-authoring-validate-url-value='#{validate_url}']" \
      "[data-ansible-authoring-resource-type-value='#{resource_type}']" \
      "[data-ansible-authoring-max-bytes-value='262144']"
    assert_select selector
    assert_select "[data-ansible-authoring-target=list]"
    assert_select "[data-ansible-authoring-target=form]"
    assert_select "textarea[spellcheck=false][data-ansible-authoring-target=yaml]"
    assert_select "[aria-live=polite][data-ansible-authoring-target=validation]"
    assert_select "[data-ansible-authoring-target=dirty]", text: /Unsaved changes/
    assert_select "p", text: /Do not place credentials, tokens, passwords, or private keys in raw YAML/
  end

  def create_stored_secrets
    ControlCenter::Ansible::Credential.create!(
      name: "secret", auth_type: "password", username: "ansible",
      ssh_password: "credential-secret", created_by: @user
    )
    variable_set = ControlCenter::Ansible::VariableSet.create!(name: "secret", created_by: @user)
    variable_set.variables.create!(
      name: "token", value_type: "string", serialized_value: '"variable-secret"', secret: true
    )
  end
end
