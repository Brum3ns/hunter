require "test_helper"

class Assistant::ActivationTest < ActiveSupport::TestCase
  # These tests exercise the credential-derived path in isolation, so they stub
  # Config.configuration_reasons to empty — Assistant::ConfigTest already covers
  # the configuration-reasons gate taking precedence over credentials.
  def test_a_valid_provider_key_activates_the_assistant
    with_keys("ASSISTANT_ANTHROPIC_API_KEY" => "sk-live") do
      stub_methods(Assistant::Config, configuration_reasons: -> { [] }) do
        state = Assistant::Activation.state

        assert_predicate state, :active
        assert_equal [ "anthropic_primary" ], state.available_slugs
      end
    end
  end

  def test_empty_keys_leave_the_assistant_inactive_with_a_reason
    with_keys("ASSISTANT_ANTHROPIC_API_KEY" => "", "ASSISTANT_OPENAI_API_KEY" => "") do
      stub_methods(Assistant::Config, configuration_reasons: -> { [] }) do
        state = Assistant::Activation.state

        refute_predicate state, :active
        assert_equal "no_provider_credentials", state.reason
        assert_empty state.available_slugs
      end
    end
  end

  def test_the_environment_kill_override_forces_the_assistant_off
    with_keys("ASSISTANT_ANTHROPIC_API_KEY" => "sk-live") do
      stub_methods(Assistant::Config, configured: ->(key) { key == "ASSISTANT_ENABLED" ? "false" : nil }) do
        state = Assistant::Activation.state

        refute_predicate state, :active
        assert_equal "disabled_by_environment", state.reason
      end
    end
  end

  def test_an_administrator_disable_survives_a_valid_key
    Assistant::Setting.instance.disable!(user: users(:one))

    with_keys("ASSISTANT_ANTHROPIC_API_KEY" => "sk-live") do
      refute Assistant::Config.enabled? && Assistant::Setting.instance.assistant_enabled?
    end
  end

  def test_a_new_singleton_defaults_to_enabled
    Assistant::Setting.delete_all

    assert_predicate Assistant::Setting.instance, :assistant_enabled?
  end

  def test_activation_audit_carries_no_secret_material
    with_keys("ASSISTANT_ANTHROPIC_API_KEY" => "sk-live-canary") do
      stub_methods(Assistant::Config, configuration_reasons: -> { [] }) do
        event = Assistant::Activation.audit_payload(Assistant::Activation.state)

        refute_includes event.to_json, "sk-live-canary"
        assert_equal [ "anthropic_primary" ], event[:available_slugs]
      end
    end
  end

  private

  # Isolates every catalog provider variable, not just the ones given: a bare
  # tmpdir used to guarantee an unmentioned provider's key file was absent, and
  # an unmentioned env var must be unset the same way or a value already
  # present in this process's environment would silently join available_slugs.
  def with_keys(values)
    all_vars = Assistant::ProviderCatalog.entries.values.map(&:secret_env)
    originals = all_vars.to_h { |key| [ key, ENV[key] ] }
    all_vars.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
