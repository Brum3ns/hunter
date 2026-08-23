require "test_helper"

class Assistant::TurnGrantTest < ActiveSupport::TestCase
  test "a legacy resource grant carries no unrelated module scopes" do
    issue!
    grant = Assistant::TurnGrant.order(:id).last
    assert_equal [], grant.read_scopes
  end

  test "read_scopes cannot be changed after issue" do
    issue!
    grant = Assistant::TurnGrant.order(:id).last
    grant.read_scopes = grant.read_scopes + [ "targets_read" ]
    refute grant.valid?
    assert_includes grant.errors[:read_scopes], "cannot be changed"
  end

  test "unknown read scope slugs are rejected on create" do
    issue!
    template = Assistant::TurnGrant.order(:id).last
    clone = Assistant::TurnGrant.new(
      template.attributes.except("id", "created_at", "updated_at", "token_digest")
    )
    clone.token_digest = Assistant::TurnGrant.digest("another-secret")
    clone.read_scopes = [ "bogus" ]
    refute clone.valid?
    assert(clone.errors[:read_scopes].any? { |message| message.include?("unknown") })
  end

  test "READ_SCOPES is the exact reviewed operational read set" do
    assert_equal(
      %w[
        control_center_ansible_credentials_read
        control_center_ansible_inventories_read
        control_center_ansible_read
        control_center_ansible_runs_read
        control_center_ansible_variables_read
        control_center_jobs_read
        control_center_templates_read
        cves_read
        hunter_capabilities_read
        programs_read
        sitemap_read
        targets_read
        vulnerabilities_read
      ],
      Assistant::TurnGrant::READ_SCOPES
    )
  end

  test "read_scopes_are_known accepts every reviewed read scope" do
    clone = clone_of_issued_grant("phase-2c-secret")
    clone.read_scopes = Assistant::TurnGrant::READ_SCOPES
    assert clone.valid?, clone.errors.full_messages.join(", ")
  end

  test "read_scopes_are_known rejects a known slug mixed with an unknown one" do
    clone = clone_of_issued_grant("phase-2c-bogus-secret")
    clone.read_scopes = %w[cves_read bogus]
    refute clone.valid?
    assert(clone.errors[:read_scopes].any? { |message| message.include?("unknown") })
  end

  test "an issued grant carries no write scopes when the write toggle is off" do
    Assistant::Setting.instance.update!(control_center_write_enabled: false)
    issue!
    grant = Assistant::TurnGrant.order(:id).last
    assert_equal [], grant.write_scopes
  end

  test "write_scopes cannot be changed after issue" do
    issue!
    grant = Assistant::TurnGrant.order(:id).last
    grant.write_scopes = grant.write_scopes + [ "control_center_templates_write" ]
    refute grant.valid?
    assert_includes grant.errors[:write_scopes], "cannot be changed"
  end

  test "unknown write scope slugs are rejected on create" do
    clone = clone_of_issued_grant("write-scope-bogus-secret")
    clone.write_scopes = [ "bogus" ]
    refute clone.valid?
    assert(clone.errors[:write_scopes].any? { |message| message.include?("unknown") })
  end

  test "write_scopes_are_known accepts every WRITE_SCOPES slug" do
    clone = clone_of_issued_grant("write-scope-valid-secret")
    clone.write_scopes = Assistant::TurnGrant::WRITE_SCOPES
    assert clone.valid?, clone.errors.full_messages.join(", ")
  end

  test "WRITE_SCOPES is the exact independently revocable operational effect set" do
    assert_equal(
      %w[
        control_center_ansible_edit
        control_center_ansible_inventories_create
        control_center_ansible_inventories_edit
        control_center_ansible_inventory_connectivity_test
        control_center_ansible_inventory_host_key_scan
        control_center_ansible_inventory_host_keys_confirm
        control_center_ansible_inventory_syntax_check
        control_center_ansible_playbooks_export
        control_center_ansible_run_groups_cancel
        control_center_ansible_run_groups_launch
        control_center_ansible_runs_cancel
        control_center_ansible_variable_sets_create
        control_center_ansible_variable_sets_edit
        control_center_ansible_variables_create
        control_center_ansible_variables_edit
        control_center_ansible_write
        control_center_jobs_submit
        control_center_templates_edit
        control_center_templates_write
        vulnerabilities_create
        vulnerabilities_update
      ],
      Assistant::TurnGrant::WRITE_SCOPES
    )
    assert_empty Assistant::TurnGrant::READ_SCOPES & Assistant::TurnGrant::WRITE_SCOPES
  end

  test "grants accept the approved hard call ceiling" do
    clone = clone_of_issued_grant("workflow-scale-secret")
    clone.max_calls = 128

    assert clone.valid?, clone.errors.full_messages.join(", ")
  end

  private

  def clone_of_issued_grant(secret)
    issue!
    template = Assistant::TurnGrant.order(:id).last
    clone = Assistant::TurnGrant.new(
      template.attributes.except("id", "created_at", "updated_at", "token_digest")
    )
    clone.token_digest = Assistant::TurnGrant.digest(secret)
    clone
  end

  def issue!
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "target", id: "abc" } ],
      tools: [ "get_selected_context" ]
    )
  end
end
