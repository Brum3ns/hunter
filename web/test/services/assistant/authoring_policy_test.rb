require "test_helper"

class Assistant::AuthoringPolicyTest < ActiveSupport::TestCase
  test "returns the versioned unrestricted non-secret Whiterabbit policy" do
    policy = Assistant::AuthoringPolicy.for("whiterabbit_template")

    assert_equal 1, policy.fetch(:schema_version)
    assert_equal "whiterabbit-v2", policy.fetch(:validation_version)
    assert_equal "unrestricted", policy.fetch(:command_policy)
    refute policy.key?(:command_allowlist)
    assert_equal [ "closed_schema", "secret_material", "template_validator" ],
      policy.fetch(:required_validation)
    assert_equal [ "", "|", "&&", "||" ], policy.fetch(:operators)
    assert_equal %w[__TARGET_FILE__ __TARGET_STDIN__ __UUID__], policy.fetch(:placeholders)
    refute_includes policy.to_json, "secret_ref"
  end

  test "returns nil for an unsupported artifact type" do
    assert_nil Assistant::AuthoringPolicy.for("shell_script")
  end
end
