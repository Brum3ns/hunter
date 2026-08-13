require "test_helper"

class Assistant::ChatBackendTest < ActiveSupport::TestCase
  test "fetch resolves only the two enabled reviewed synthetic rows" do
    assert_equal assistant_provider_profiles(:codex), Assistant::ChatBackend.fetch("codex")
    assert_equal assistant_provider_profiles(:claude_code), Assistant::ChatBackend.fetch("claude_code")
    assert_nil Assistant::ChatBackend.fetch("openai_primary")
    assert_nil Assistant::ChatBackend.fetch("../codex")
  end

  test "slug for resolves only direct backend catalog bindings" do
    assert_equal "codex", Assistant::ChatBackend.slug_for(assistant_provider_profiles(:codex))
    assert_equal "claude_code", Assistant::ChatBackend.slug_for(assistant_provider_profiles(:claude_code))
    assert_nil Assistant::ChatBackend.slug_for(assistant_provider_profiles(:openai))
    assert_nil Assistant::ChatBackend.slug_for(nil)
  end

  test "descriptors expose no profile secret or arbitrary model contract" do
    payload = Assistant::ChatBackend.descriptors

    assert_equal %w[codex claude_code], payload.map { |item| item.fetch(:slug) }
    payload.each do |item|
      assert_equal %i[slug brand name enabled retention_posture reviewed_at], item.keys
    end
    refute_match(/secret_ref|api_key|provider_profile_id|model/, payload.to_json)
  end
end
