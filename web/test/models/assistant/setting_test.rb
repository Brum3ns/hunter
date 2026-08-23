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

  test "operational MCP access defaults on with no disabled capabilities" do
    setting = Assistant::Setting.instance

    assert setting.operational_access_enabled?
    assert_equal [], setting.disabled_capability_tools
    assert_equal [], setting.disabled_capability_effects
    assert_equal [], setting.disabled_capability_modules
  end

  test "capability disables accept only exact reviewed names" do
    setting = Assistant::Setting.instance
    setting.disabled_capability_tools = [ "submit_whiterabbit_job", "*" ]
    setting.disabled_capability_effects = [ "execute", "all" ]
    setting.disabled_capability_modules = [ "targets", "unknown" ]

    refute setting.valid?
    assert_includes setting.errors[:disabled_capability_tools], "contains unknown names: *"
    assert_includes setting.errors[:disabled_capability_effects], "contains unknown names: all"
    assert_includes setting.errors[:disabled_capability_modules], "contains unknown names: unknown"
  end

  test "blank multi-select sentinels clear capability disables" do
    setting = Assistant::Setting.instance
    setting.update!(
      disabled_capability_tools: [ "" ],
      disabled_capability_effects: [ "" ],
      disabled_capability_modules: [ "" ]
    )

    assert_empty setting.disabled_capability_tools
    assert_empty setting.disabled_capability_effects
    assert_empty setting.disabled_capability_modules
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

  test "conversation management defaults on independently of Control Center authoring" do
    setting = Assistant::Setting.instance

    assert setting.conversation_management_enabled?
    assert setting.control_center_write_enabled?

    setting.disable_conversation_management!(user: users(:one))

    refute setting.reload.conversation_management_enabled?
    assert setting.control_center_write_enabled?
  end

  test "conversation management toggle changes are attributed and audited" do
    setting = Assistant::Setting.instance
    user = users(:one)

    assert_difference "Assistant::AuditEvent.count", 1 do
      setting.disable_conversation_management!(user: user)
    end
    disabled = Assistant::AuditEvent.order(:id).last
    assert_equal "conversation_management.disabled", disabled.event
    assert_equal user.id, disabled.user_id
    assert_equal({
      "operation" => "conversation_management", "outcome" => "disabled"
    }, disabled.metadata)

    assert_difference "Assistant::AuditEvent.count", 1 do
      setting.enable_conversation_management!(user: user)
    end
    enabled = Assistant::AuditEvent.order(:id).last
    assert_equal "conversation_management.enabled", enabled.event
    assert_equal user.id, enabled.user_id
    assert_equal "enabled", enabled.metadata["outcome"]
  end
end
