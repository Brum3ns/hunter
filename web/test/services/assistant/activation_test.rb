require "test_helper"

class Assistant::ActivationTest < ActiveSupport::TestCase
  def test_complete_configuration_activates_every_direct_backend_without_provider_keys
    stub_methods(Assistant::Config, {
      configured: ->(_key) { nil },
      configuration_reasons: -> { [] }
    }) do
      stub_methods(Assistant::ProviderCredentials, {
        available_slugs: -> { flunk "activation consulted provider credentials" }
      }) do
        state = Assistant::Activation.state

        assert_predicate state, :active
        assert_equal "active", state.reason
        assert_equal %w[codex claude_code], state.available_slugs
      end
    end
  end

  def test_a_configuration_reason_still_disables_the_assistant
    stub_methods(Assistant::Config, {
      configured: ->(_key) { nil },
      configuration_reasons: -> { [ "missing_admin_username" ] }
    }) do
      state = Assistant::Activation.state

      refute_predicate state, :active
      assert_equal "missing_admin_username", state.reason
      assert_empty state.available_slugs
    end
  end

  def test_the_environment_kill_override_forces_the_assistant_off
    stub_methods(Assistant::Config, configured: ->(key) { key == "ASSISTANT_ENABLED" ? "false" : nil }) do
      state = Assistant::Activation.state

      refute_predicate state, :active
      assert_equal "disabled_by_environment", state.reason
    end
  end

  def test_an_administrator_disable_remains_an_independent_database_kill_switch
    Assistant::Setting.instance.disable!(user: users(:one))

    stub_methods(Assistant::Config, enabled?: true) do
      refute Assistant::Config.enabled? && Assistant::Setting.instance.assistant_enabled?
    end
  end

  def test_a_new_singleton_defaults_to_enabled
    Assistant::Setting.delete_all

    assert_predicate Assistant::Setting.instance, :assistant_enabled?
  end

  def test_activation_audit_carries_no_secret_material
    stub_methods(Assistant::Config, {
      configured: ->(_key) { nil },
      configuration_reasons: -> { [] }
    }) do
      event = Assistant::Activation.audit_payload(Assistant::Activation.state)

      refute_match(/api_key|secret_ref|credential/i, event.to_json)
      assert_equal %w[codex claude_code], event[:available_slugs]
    end
  end
end
