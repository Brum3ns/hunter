require "test_helper"

class Assistant::Grants::IssuerTest < ActiveSupport::TestCase
  test "issued grant carries the read scopes and read tools" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: Assistant::Grants::Issuer::TOOLS
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    assert_equal Assistant::TurnGrant::READ_SCOPES, grant.read_scopes
    assert_includes grant.tools, "list_targets"
    assert_includes grant.tools, "get_target"
  end

  test "read tools are members of the issuer tool allowlist" do
    assert_includes Assistant::Grants::Issuer::TOOLS, "list_targets"
    assert_includes Assistant::Grants::Issuer::TOOLS, "get_target"
  end

  test "a requested read tool grants only its reviewed scope" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_cves" ]
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    assert_equal %w[cves_read], grant.read_scopes
    assert_equal [], grant.write_scopes
  end

  test "Issuer.call grants every reviewed operational tool into the persisted grant" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: Assistant::Grants::Issuer::TOOLS
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    %w[
      analyze_targets list_new_cves create_vulnerability
      submit_whiterabbit_job list_ansible_inventories
      create_nonsecret_ansible_variable launch_ansible_run_group
      cancel_ansible_run list_run_events
    ].each do |tool|
      assert_includes grant.tools, tool
    end
  end

  test "CHAT_TOOLS exactly matches the reviewed operational catalog" do
    expected = Assistant::CapabilityCatalog.load.tools.map { |tool| tool.fetch("name") }

    assert_equal expected, Assistant::Grants::Issuer::CHAT_TOOLS
    assert_equal 70, Assistant::Grants::Issuer::CHAT_TOOLS.length
  end

  test "create tools are members of the issuer tool allowlist" do
    assert_includes Assistant::Grants::Issuer::TOOLS, "create_whiterabbit_template"
    assert_includes Assistant::Grants::Issuer::TOOLS, "create_ansible_playbook"
  end

  test "issued grant carries write scopes and create tools when the write toggle is on" do
    Assistant::Setting.instance.update!(control_center_write_enabled: true)

    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: Assistant::Grants::Issuer::TOOLS
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    assert_equal Assistant::TurnGrant::WRITE_SCOPES, grant.write_scopes
    assert_includes grant.tools, "create_whiterabbit_template"
    assert_includes grant.tools, "create_ansible_playbook"
  end

  test "each authoring tool grants only its dedicated write scope" do
    {
      "create_whiterabbit_template" => "control_center_templates_write",
      "edit_whiterabbit_template" => "control_center_templates_edit",
      "create_ansible_playbook" => "control_center_ansible_write",
      "edit_ansible_playbook" => "control_center_ansible_edit"
    }.each do |tool, scope|
      raw = Assistant::Grants::Issuer.call(
        turn: assistant_turns(:created), resources: [], tools: [ tool ]
      )
      grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

      assert_equal [ scope ], grant.write_scopes
    end
  end

  test "legacy Control Center write toggle revokes Control Center effects but not other modules" do
    Assistant::Setting.instance.update!(control_center_write_enabled: false)

    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: Assistant::Grants::Issuer::TOOLS
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    assert_includes grant.write_scopes, "vulnerabilities_create"
    refute_includes grant.write_scopes, "control_center_templates_write"
    refute_includes grant.tools, "create_whiterabbit_template"
    refute_includes grant.tools, "create_ansible_playbook"
    assert_includes grant.tools, "create_vulnerability"
  end
end
