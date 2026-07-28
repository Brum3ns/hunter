require "test_helper"

class Assistant::ProviderCatalogTest < ActiveSupport::TestCase
  test "fetch returns immutable approved metadata" do
    entry = Assistant::ProviderCatalog.fetch!("openai_primary")

    assert_equal "openai", entry.provider
    assert_equal "gpt-5", entry.model
    assert_equal "openai_primary", entry.secret_ref
    assert entry.frozen?
  end

  test "unknown entries fail closed" do
    assert_raises(KeyError) { Assistant::ProviderCatalog.fetch!("custom") }
  end

  test "catalog entries cannot configure endpoints or headers" do
    Assistant::ProviderCatalog.entries.each_value do |entry|
      refute_respond_to entry, :base_url
      refute_respond_to entry, :headers
    end
  end
end
