require "test_helper"

class AssistantQueueContractsTest < ActiveSupport::TestCase
  CONTRACTS = %w[turn_job assistant_event validation_job validation_event].freeze

  test "all assistant queue contracts are closed version-one JSON schemas" do
    CONTRACTS.each do |name|
      schema = JSON.parse(File.read(Rails.root.join("../assistant/contracts/v1/#{name}.json")))
      assert_equal "https://json-schema.org/draft/2020-12/schema", schema.fetch("$schema")
      assert_equal 1, schema.dig("properties", "schema_version", "const")
      assert_closed_objects(schema)
    end
  end

  test "turn contract bounds bodies references and grants" do
    schema = JSON.parse(File.read(Rails.root.join("../assistant/contracts/v1/turn_job.json")))

    assert_equal 65_536, schema.dig("properties", "user_message", "maxLength")
    assert_equal 10, schema.dig("properties", "context_references", "maxItems")
    assert_equal 256, schema.dig("properties", "turn_grant", "maxLength")
    refute_includes schema.to_json, "service_token"
    refute_includes schema.to_json, "provider_api_key"
  end

  private

  def assert_closed_objects(value)
    case value
    when Hash
      if value["type"] == "object"
        assert_equal false, value["additionalProperties"], "object schema must be closed"
      end
      value.each_value { |child| assert_closed_objects(child) }
    when Array
      value.each { |child| assert_closed_objects(child) }
    end
  end
end
