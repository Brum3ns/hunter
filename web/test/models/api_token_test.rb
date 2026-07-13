require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "generate stores only the digest and returns the raw token once" do
    record, raw = ApiToken.generate(user: @user, name: "ci")

    assert_equal @user, record.user
    assert_equal "ci", record.name
    assert raw.present?
    assert_not_equal raw, record.token_digest
    assert_equal ApiToken.digest(raw), record.token_digest
  end

  test "authenticate returns the token record and touches last_used_at" do
    _record, raw = ApiToken.generate(user: @user, name: "ci")
    freeze_time do
      token = ApiToken.authenticate(raw)
      assert_kind_of ApiToken, token
      assert_equal @user, token.user
      assert_in_delta Time.current, token.last_used_at, 1
    end
  end

  test "generate defaults to wildcard scope and empty filter" do
    record, _raw = ApiToken.generate(user: @user, name: "ci")
    assert_equal ["*"], record.scopes
    assert_equal({}, record.cve_filter)
  end

  test "generate accepts explicit scopes" do
    record, _raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    assert_equal ["cves"], record.scopes
  end

  test "allows_scope? honours wildcard and exact slug" do
    wild = ApiToken.generate(user: @user, name: "w").first
    cve  = ApiToken.generate(user: @user, name: "c", scopes: ["cves"]).first
    assert wild.allows_scope?(:vulnerabilities)
    assert cve.allows_scope?("cves")
    assert_not cve.allows_scope?(:vulnerabilities)
  end

  test "authenticate returns nil for an unknown or blank token" do
    assert_nil ApiToken.authenticate("not-a-real-token")
    assert_nil ApiToken.authenticate("")
    assert_nil ApiToken.authenticate(nil)
  end
end
