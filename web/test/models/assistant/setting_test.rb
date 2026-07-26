require "test_helper"

class Assistant::SettingTest < ActiveSupport::TestCase
  test "instance returns the single settings row" do
    assert_equal assistant_settings(:default), Assistant::Setting.instance
  end

  test "settings enforce transcript and audit bounds" do
    setting = Assistant::Setting.new(
      singleton_key: true,
      transcript_retention_days: 31,
      audit_retention_days: 0
    )

    refute setting.valid?
    assert_includes setting.errors[:transcript_retention_days], "must be in 1..30"
    assert_includes setting.errors[:audit_retention_days], "must be in 1..365"
  end

  test "disable and enable preserve the responsible administrator" do
    setting = assistant_settings(:default)
    user = users(:one)

    setting.enable!
    assert setting.assistant_enabled?

    setting.disable!(user: user)
    refute setting.assistant_enabled?
    assert_equal user, setting.disabled_by
    assert_not_nil setting.disabled_at
  end
end
