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

  test "issued grant read_scopes equal the full phase 2c allowlist" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_cves" ]
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    assert_equal(
      %w[targets cves vulnerabilities sitemap programs control_center_templates control_center_jobs control_center_ansible],
      grant.read_scopes
    )
  end

  test "Issuer.call grants the phase 2c read tools into the persisted grant" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: Assistant::Grants::Issuer::TOOLS
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    %w[
      list_cves get_cve list_vulnerabilities list_endpoints
      list_programs list_templates list_jobs list_playbooks
      list_run_groups get_run list_run_events
    ].each do |tool|
      assert_includes grant.tools, tool
    end
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

  test "issued grant has no write scopes or create tools when the write toggle is off" do
    Assistant::Setting.instance.update!(control_center_write_enabled: false)

    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: Assistant::Grants::Issuer::TOOLS
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    assert_equal [], grant.write_scopes
    refute_includes grant.tools, "create_whiterabbit_template"
    refute_includes grant.tools, "create_ansible_playbook"
  end
end
