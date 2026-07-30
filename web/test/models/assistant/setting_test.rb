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

  test "control_center_write_enabled defaults to true" do
    assert Assistant::Setting.instance.control_center_write_enabled?
  end

  test "disable_control_center_write! flips the flag and audits" do
    user = users(:one)

    assert_difference "Assistant::AuditEvent.count", 1 do
      Assistant::Setting.disable_control_center_write!(user: user)
    end

    refute Assistant::Setting.instance.control_center_write_enabled?
    event = Assistant::AuditEvent.order(:created_at).last
    assert_equal "control_center_write.disabled", event.event
    assert_equal user.id, event.user_id
    assert_equal "disabled", event.metadata["outcome"]
  end

  test "enable_control_center_write! flips the flag back and audits" do
    Assistant::Setting.disable_control_center_write!(user: users(:one))

    assert_difference "Assistant::AuditEvent.count", 1 do
      Assistant::Setting.enable_control_center_write!
    end

    assert Assistant::Setting.instance.control_center_write_enabled?
    event = Assistant::AuditEvent.order(:created_at).last
    assert_equal "control_center_write.enabled", event.event
    assert_equal "enabled", event.metadata["outcome"]
  end
end
