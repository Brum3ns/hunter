require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  test "assistant seeds install both direct backends idempotently without re-enabling rows" do
    assistant_conversations(:codex).destroy!
    assistant_provider_profiles(:codex).destroy!
    assistant_provider_profiles(:claude_code).update!(enabled: false)

    with_seed_environment do
      stub_methods(HunterMongo, healthy?: false) do
        capture_io do
          2.times { Rails.application.load_seed }
        end
      end
    end

    codex = Assistant::ProviderProfile.find_by(catalog_slug: "codex")
    claude_code = Assistant::ProviderProfile.find_by!(catalog_slug: "claude_code")
    assert codex, "seeds omitted the Codex backend"
    assert_equal "Codex", codex.name
    assert_predicate codex, :enabled?
    assert_equal "Claude Code", claude_code.name
    refute_predicate claude_code, :enabled?
    assert_equal 1, Assistant::ProviderProfile.where(catalog_slug: "codex").count
    assert_equal 1, Assistant::ProviderProfile.where(catalog_slug: "claude_code").count
  end

  private

  def with_seed_environment
    values = {
      "ADMIN_USERNAME" => users(:one).username,
      "ADMIN_PASSWORD" => "test-seed-password",
      "RUNNER_TOKEN" => nil,
      "ASSISTANT_MCP_HUNTER_TOKEN" => nil
    }
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
