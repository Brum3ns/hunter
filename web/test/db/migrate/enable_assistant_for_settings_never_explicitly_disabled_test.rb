require "test_helper"

require Rails.root.join("db/migrate/20260726000001_enable_assistant_for_settings_never_explicitly_disabled")

# Guards Important 2 of the 2026-07-26 whole-branch review: an upgraded host
# with a pre-existing assistant_settings row (assistant_enabled: false, the
# column default) must come back enabled after this migration runs, unless an
# administrator had already disabled it deliberately.
class EnableAssistantForSettingsNeverExplicitlyDisabledTest < ActiveSupport::TestCase
  test "enables a settings row nobody ever explicitly disabled" do
    setting = assistant_settings(:default)
    refute setting.assistant_enabled?
    assert_nil setting.disabled_at

    EnableAssistantForSettingsNeverExplicitlyDisabled.new.up

    assert setting.reload.assistant_enabled?
  end

  test "leaves a deliberately disabled settings row disabled" do
    setting = assistant_settings(:default)
    setting.disable!(user: users(:one))

    EnableAssistantForSettingsNeverExplicitlyDisabled.new.up

    refute setting.reload.assistant_enabled?
    assert_not_nil setting.disabled_at
  end

  test "is a no-op for a settings row already enabled" do
    setting = assistant_settings(:default)
    setting.enable!

    EnableAssistantForSettingsNeverExplicitlyDisabled.new.up

    assert setting.reload.assistant_enabled?
  end
end
