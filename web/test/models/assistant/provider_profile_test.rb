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
    profile = assistant_provider_profiles(:openai)
    profile.tool_call_limit = 129

    refute profile.valid?
    assert_includes profile.errors[:tool_call_limit], "must be less than or equal to 128"

    profile.tool_call_limit = 128
    assert profile.valid?, profile.errors.full_messages.join(", ")
  end

  test "direct chat helpers derive only from the immutable catalog binding" do
    codex = assistant_provider_profiles(:codex)
    claude_code = assistant_provider_profiles(:claude_code)
    legacy = assistant_provider_profiles(:openai)
    legacy.assign_attributes(name: "Codex", provider: "codex")

    assert codex.codex?
    assert codex.direct_chat?
    assert_equal "codex", codex.chat_backend_slug
    assert claude_code.claude_code?
    assert claude_code.direct_chat?
    assert_equal "claude_code", claude_code.chat_backend_slug
    refute legacy.codex?
    refute legacy.claude_code?
    refute legacy.direct_chat?
    assert_nil legacy.chat_backend_slug
  end

  test "persisted direct profile cannot be reclassified to a vacant legacy catalog binding" do
    assistant_provider_profiles(:anthropic).destroy!
    profile = assistant_provider_profiles(:codex)

    profile.catalog_slug = "anthropic_primary"

    refute profile.valid?
    assert_includes profile.errors[:catalog_slug], "cannot be changed"
    assert_equal "codex", profile.reload.catalog_slug
  end

  test "persisted legacy profile cannot claim a vacant direct backend binding" do
    assistant_conversations(:codex).destroy!
    assistant_provider_profiles(:codex).destroy!
    profile = assistant_provider_profiles(:openai)

    profile.catalog_slug = "codex"

    refute profile.valid?
    assert_includes profile.errors[:catalog_slug], "cannot be changed"
    assert_equal "openai_primary", profile.reload.catalog_slug
  end

  test "catalog binding remains assignable when a profile is created" do
    assistant_conversations(:codex).destroy!
    assistant_provider_profiles(:codex).destroy!

    profile = Assistant::ProviderProfile.new(
      name: "Replacement Codex",
      catalog_slug: "codex",
      retention_posture: "standard",
      reviewed_at: Time.current,
      enabled: true,
      created_by: users(:one)
    )

    assert profile.valid?
    assert_empty profile.errors[:catalog_slug]
  end
end
