require "test_helper"
require "tmpdir"

class Assistant::ActivationTest < ActiveSupport::TestCase
  # These tests exercise the credential-derived path in isolation, so they stub
  # Config.configuration_reasons to empty — Assistant::ConfigTest already covers
  # the configuration-reasons gate taking precedence over credentials.
  def test_a_valid_provider_key_activates_the_assistant
    with_keys("assistant_anthropic_api_key" => "sk-live") do |dir|
      stub_methods(Assistant::Config, configuration_reasons: -> { [] }) do
        state = Assistant::Activation.state(directory: dir)

        assert_predicate state, :active
        assert_equal [ "anthropic_primary" ], state.available_slugs
      end
    end
  end

  def test_empty_keys_leave_the_assistant_inactive_with_a_reason
    with_keys("assistant_anthropic_api_key" => "", "assistant_openai_api_key" => "") do |dir|
      stub_methods(Assistant::Config, configuration_reasons: -> { [] }) do
        state = Assistant::Activation.state(directory: dir)

        refute_predicate state, :active
        assert_equal "no_provider_credentials", state.reason
        assert_empty state.available_slugs
      end
    end
  end

  def test_the_environment_kill_override_forces_the_assistant_off
    with_keys("assistant_anthropic_api_key" => "sk-live") do |dir|
      stub_methods(Assistant::Config, configured: ->(key) { key == "ASSISTANT_ENABLED" ? "false" : nil }) do
        state = Assistant::Activation.state(directory: dir)

        refute_predicate state, :active
        assert_equal "disabled_by_environment", state.reason
      end
    end
  end

  def test_an_administrator_disable_survives_a_valid_key
    Assistant::Setting.instance.disable!(user: users(:one))

    with_keys("assistant_anthropic_api_key" => "sk-live") do |dir|
      refute Assistant::Config.enabled?(directory: dir) && Assistant::Setting.instance.assistant_enabled?
    end
  end

  def test_a_new_singleton_defaults_to_enabled
    Assistant::Setting.delete_all

    assert_predicate Assistant::Setting.instance, :assistant_enabled?
  end

  def test_activation_audit_carries_no_secret_material
    with_keys("assistant_anthropic_api_key" => "sk-live-canary") do |dir|
      stub_methods(Assistant::Config, configuration_reasons: -> { [] }) do
        event = Assistant::Activation.audit_payload(Assistant::Activation.state(directory: dir))

        refute_includes event.to_json, "sk-live-canary"
        assert_equal [ "anthropic_primary" ], event[:available_slugs]
      end
    end
  end

  private

  def with_keys(files)
    Dir.mktmpdir do |dir|
      files.each do |name, body|
        path = Pathname.new(dir).join(name)
        path.write(body)
        path.chmod(0o400)
      end
      yield dir
    end
  end
end
