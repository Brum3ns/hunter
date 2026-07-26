require "test_helper"

class Assistant::ProviderProfileTest < ActiveSupport::TestCase
  test "profile derives endpoint-sensitive fields from the reviewed catalog" do
    profile = assistant_provider_profiles(:openai)
    profile.assign_attributes(
      provider: "untrusted",
      model: "untrusted",
      secret_ref: "untrusted",
      input_limit: 1,
      output_limit: 1
    )

    assert profile.valid?
    assert_equal "openai", profile.provider
    assert_equal "gpt-5", profile.model
    assert_equal "openai_primary", profile.secret_ref
    assert_equal 32_768, profile.input_limit
    assert_equal 8_192, profile.output_limit
    refute_includes profile.dispatch_snapshot.keys, :api_key
    refute_includes profile.dispatch_snapshot.keys, :base_url
  end

  test "unknown catalog entries are rejected" do
    profile = Assistant::ProviderProfile.new(
      name: "Unknown",
      catalog_slug: "custom_endpoint",
      retention_posture: "standard",
      reviewed_at: Time.current,
      created_by: users(:one)
    )

    refute profile.valid?
    assert_includes profile.errors[:catalog_slug], "is not approved"
  end

  test "enabled profiles require a review timestamp and approved retention posture" do
    profile = Assistant::ProviderProfile.new(
      name: "Unreviewed",
      catalog_slug: "anthropic_primary",
      retention_posture: "unknown",
      enabled: true,
      created_by: users(:one)
    )

    refute profile.valid?
    assert_includes profile.errors[:reviewed_at], "must be present when enabled"
    assert_includes profile.errors[:retention_posture], "is not included in the list"
  end

  test "tool call limit is bounded by the assistant hard ceiling" do
    profile = Assistant::ProviderProfile.new(
      name: "Too many tools",
      catalog_slug: "openai_primary",
      retention_posture: "standard",
      reviewed_at: Time.current,
      tool_call_limit: 9,
      created_by: users(:one)
    )

    refute profile.valid?
    assert_includes profile.errors[:tool_call_limit], "must be less than or equal to 8"
  end
end
