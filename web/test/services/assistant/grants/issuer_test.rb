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

  test "issuer tool allowlist includes every phase 2c read tool" do
    %w[
      list_cves get_cve list_vulnerabilities get_vulnerability
      list_endpoints get_endpoint list_programs get_program
      list_templates get_template list_jobs get_job
      list_playbooks get_playbook list_run_groups get_run_group
      get_run list_run_events
    ].each do |tool|
      assert_includes Assistant::Grants::Issuer::TOOLS, tool
    end
  end
end
