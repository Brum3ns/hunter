require "test_helper"

class Assistant::CapabilityPolicyTest < ActiveSupport::TestCase
  test "allows an enabled reviewed capability by default" do
    decision = Assistant::CapabilityPolicy.check(
      tool: "submit_whiterabbit_job", settings: Assistant::Setting.instance
    )

    assert_predicate decision, :allowed?
    assert_nil decision.reason
  end

  test "an exact tool disable revokes the capability immediately" do
    setting = Assistant::Setting.instance
    setting.update!(disabled_capability_tools: [ "submit_whiterabbit_job" ])

    decision = Assistant::CapabilityPolicy.check(
      tool: "submit_whiterabbit_job", settings: setting.reload
    )

    refute_predicate decision, :allowed?
    assert_equal "capability_disabled", decision.reason
  end

  test "effect and module disables are independent" do
    setting = Assistant::Setting.instance
    setting.update!(disabled_capability_effects: [ "execute" ])

    refute Assistant::CapabilityPolicy.check(
      tool: "submit_whiterabbit_job", settings: setting
    ).allowed?
    assert Assistant::CapabilityPolicy.check(tool: "list_jobs", settings: setting).allowed?

    setting.update!(
      disabled_capability_effects: [],
      disabled_capability_modules: [ "control_center_jobs" ]
    )
    refute Assistant::CapabilityPolicy.check(tool: "list_jobs", settings: setting).allowed?
    assert Assistant::CapabilityPolicy.check(tool: "list_targets", settings: setting).allowed?
  end

  test "legacy Control Center write switch still revokes Control Center effects" do
    setting = Assistant::Setting.instance
    setting.update!(control_center_write_enabled: false)

    refute Assistant::CapabilityPolicy.check(
      tool: "create_ansible_playbook", settings: setting
    ).allowed?
    assert Assistant::CapabilityPolicy.check(tool: "list_playbooks", settings: setting).allowed?
    assert Assistant::CapabilityPolicy.check(tool: "create_vulnerability", settings: setting).allowed?
  end
end
