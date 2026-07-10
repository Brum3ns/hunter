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

  test "authenticate returns the user and touches last_used_at for a valid token" do
    _record, raw = ApiToken.generate(user: @user, name: "ci")

    freeze_time do
      assert_equal @user, ApiToken.authenticate(raw)
      assert_in_delta Time.current, ApiToken.find_by(token_digest: ApiToken.digest(raw)).last_used_at, 1
    end
  end

  test "authenticate returns nil for an unknown or blank token" do
    assert_nil ApiToken.authenticate("not-a-real-token")
    assert_nil ApiToken.authenticate("")
    assert_nil ApiToken.authenticate(nil)
  end
end
