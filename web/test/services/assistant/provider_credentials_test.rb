require "minitest/autorun"
require_relative "../../../config/environment"

class AssistantProviderCredentialsTest < Minitest::Test
  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_absent_when_the_variable_is_unset
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => nil) do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "absent", status.reason
      refute status.available
    end
  end

  def test_empty_when_the_variable_is_whitespace
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "   \n") do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "empty", status.reason
    end
  end

  def test_placeholder_when_the_shipped_example_value_is_left_in_place
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "replace_with_your_key") do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "placeholder", status.reason
    end
  end

  def test_oversize_when_the_value_exceeds_max_bytes
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "k" * (Assistant::ProviderCredentials::MAX_BYTES + 1)) do
      status = Assistant::ProviderCredentials.statuses.find { |s| s.slug == "anthropic_primary" }
      assert_equal "oversize", status.reason
    end
  end

  def test_valid_for_a_plausible_key_and_only_that_provider_becomes_available
    with_env("ASSISTANT_ANTHROPIC_API_KEY" => "sk-ant-real", "ASSISTANT_OPENAI_API_KEY" => nil) do
      assert_equal [ "anthropic_primary" ], Assistant::ProviderCredentials.available_slugs
    end
  end

  def test_statuses_takes_no_keyword_arguments
    assert_equal 0, Assistant::ProviderCredentials.method(:statuses).arity
  end
end
