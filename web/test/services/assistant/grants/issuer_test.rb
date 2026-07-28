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
end
