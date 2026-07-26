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

  test "production validation fails closed when enabled security settings are missing" do
    values = { "ASSISTANT_ENABLED" => "true" }

    # Activation is derived from provider credentials now, so drive
    # validate_production!'s "enabled" branch by stubbing enabled? directly
    # rather than relying on ASSISTANT_ENABLED (a kill switch, not an opt-in).
    stub_methods(Assistant::Config, configured: ->(key) { values[key] }, enabled?: true) do
      error = assert_raises(RuntimeError) { Assistant::Config.validate_production! }
      assert_includes error.message, "ADMIN_USERNAME must be set"
      assert_includes error.message, "CONTROL_CENTER_COMMAND_ALLOWLIST must be set"
      assert_includes error.message, "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST must be set"
    end
  end

  test "production validation accepts a complete enabled configuration" do
    values = {
      "ASSISTANT_ENABLED" => "true",
      "ADMIN_USERNAME" => "admin",
      "CONTROL_CENTER_COMMAND_ALLOWLIST" => "httpx,nuclei",
      "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "ansible.builtin.uri"
    }

    stub_methods(Assistant::Config, configured: ->(key) { values[key] }, enabled?: true) do
      assert_nil Assistant::Config.validate_production!
    end
  end
end
