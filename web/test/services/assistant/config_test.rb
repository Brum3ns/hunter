require "test_helper"

class Assistant::ConfigTest < ActiveSupport::TestCase
  test "hard ceilings cannot be raised by environment configuration" do
    stub_methods(Assistant::Config, configured: ->(_key) { "999999" }) do
      assert_equal 300.seconds, Assistant::Config.grant_ttl
      assert_equal 10, Assistant::Config.max_records
      assert_equal 8, Assistant::Config.max_tool_calls
      assert_equal 65_536, Assistant::Config.max_result_bytes
      assert_equal 262_144, Assistant::Config.max_total_bytes
      assert_equal 10, Assistant::Config.turn_starts_per_minute
      assert_equal 60, Assistant::Config.turn_starts_per_hour
      assert_equal 2, Assistant::Config.max_concurrent_turns
      assert_equal 1, Assistant::Config.max_validations_per_turn
    end
  end

  test "deployment configuration can lower hard ceilings" do
    values = {
      "ASSISTANT_GRANT_TTL_SECONDS" => "120",
      "ASSISTANT_MAX_RECORDS" => "4",
      "ASSISTANT_MAX_TOOL_CALLS" => "3",
      "ASSISTANT_MAX_RESULT_BYTES" => "4096",
      "ASSISTANT_MAX_TOTAL_BYTES" => "8192",
      "ASSISTANT_TURN_STARTS_PER_MINUTE" => "4",
      "ASSISTANT_TURN_STARTS_PER_HOUR" => "20",
      "ASSISTANT_MAX_CONCURRENT_TURNS" => "1",
      "ASSISTANT_MAX_VALIDATIONS_PER_TURN" => "1"
    }

    stub_methods(Assistant::Config, configured: ->(key) { values[key] }) do
      assert_equal 120.seconds, Assistant::Config.grant_ttl
      assert_equal 4, Assistant::Config.max_records
      assert_equal 3, Assistant::Config.max_tool_calls
      assert_equal 4_096, Assistant::Config.max_result_bytes
      assert_equal 8_192, Assistant::Config.max_total_bytes
      assert_equal 4, Assistant::Config.turn_starts_per_minute
      assert_equal 20, Assistant::Config.turn_starts_per_hour
      assert_equal 1, Assistant::Config.max_concurrent_turns
      assert_equal 1, Assistant::Config.max_validations_per_turn
    end
  end

  test "retention uses secure defaults and rejects values outside its bounds" do
    stub_methods(Assistant::Config, configured: ->(_key) { nil }) do
      assert_equal 7, Assistant::Config.transcript_retention_days
      assert_equal 90, Assistant::Config.audit_retention_days
    end

    stub_methods(Assistant::Config, configured: ->(key) { key == "ASSISTANT_TRANSCRIPT_DAYS" ? "31" : nil }) do
      error = assert_raises(ArgumentError) { Assistant::Config.transcript_retention_days }
      assert_equal "ASSISTANT_TRANSCRIPT_DAYS must be in 1..30", error.message
    end
  end

  test "invalid ceiling values fail closed to the hard ceiling" do
    stub_methods(Assistant::Config, configured: ->(_key) { "not-an-integer" }) do
      assert_equal 300.seconds, Assistant::Config.grant_ttl
      assert_equal 10, Assistant::Config.max_records
    end
  end

  test "missing configuration yields reason codes instead of raising" do
    stub_methods(Assistant::Config, configured: ->(_key) { nil }) do
      reasons = Assistant::Config.configuration_reasons

      assert_includes reasons, "missing_admin_username"
      assert_includes reasons, "missing_command_allowlist"
      assert_includes reasons, "missing_ansible_module_allowlist"
    end
  end

  test "the initializer never raises on incomplete configuration" do
    stub_methods(Assistant::Config, configured: ->(_key) { nil }) do
      assert_nothing_raised { Assistant::Activation.state }
    end
  end

  # Activation is derived from provider credentials now, but a configuration
  # problem must still disable the assistant rather than silently activate it
  # (ASSISTANT_ENABLED is a kill switch, not an opt-in — configuration
  # completeness is checked independently of that override).
  test "a configuration problem disables rather than activates" do
    original = ENV["ASSISTANT_ANTHROPIC_API_KEY"]
    ENV["ASSISTANT_ANTHROPIC_API_KEY"] = "sk-live"

    begin
      stub_methods(Assistant::Config, configuration_reasons: -> { [ "missing_admin_username" ] }) do
        state = Assistant::Activation.state

        refute_predicate state, :active
        assert_equal "missing_admin_username", state.reason
      end
    ensure
      ENV["ASSISTANT_ANTHROPIC_API_KEY"] = original
    end
  end

  test "a complete configuration yields no reason codes" do
    values = {
      "ADMIN_USERNAME" => "admin",
      "CONTROL_CENTER_COMMAND_ALLOWLIST" => "httpx,nuclei",
      "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "ansible.builtin.uri"
    }

    stub_methods(Assistant::Config, configured: ->(key) { values[key] }) do
      assert_empty Assistant::Config.configuration_reasons
    end
  end

  # The three required settings are populated so this drives the retention
  # branch specifically rather than collecting missing-setting reasons.
  test "an out-of-range retention window yields its own reason code" do
    values = {
      "ADMIN_USERNAME" => "admin",
      "CONTROL_CENTER_COMMAND_ALLOWLIST" => "httpx,nuclei",
      "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "ansible.builtin.uri",
      "ASSISTANT_TRANSCRIPT_DAYS" => "31"
    }

    stub_methods(Assistant::Config, configured: ->(key) { values[key] }) do
      assert_includes Assistant::Config.configuration_reasons, "invalid_retention_window"
    end
  end
end
