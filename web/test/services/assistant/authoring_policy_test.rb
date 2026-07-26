require "test_helper"

class Assistant::AuthoringPolicyTest < ActiveSupport::TestCase
  test "returns the versioned non-secret Whiterabbit policy" do
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx", "nuclei" ]) do
      policy = Assistant::AuthoringPolicy.for("whiterabbit_template")

      assert_equal 1, policy.fetch(:schema_version)
      assert_equal "whiterabbit-v1", policy.fetch(:validation_version)
      assert_equal %w[httpx nuclei], policy.fetch(:command_allowlist)
      assert_equal [ "", "|", "&&", "||" ], policy.fetch(:operators)
      assert_equal %w[__TARGET_FILE__ __TARGET_STDIN__ __UUID__], policy.fetch(:placeholders)
      refute_includes policy.to_json, "secret_ref"
    end
  end

  test "returns nil for an unsupported artifact type" do
    assert_nil Assistant::AuthoringPolicy.for("shell_script")
  end
end
