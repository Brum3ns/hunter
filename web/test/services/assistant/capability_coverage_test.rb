require "test_helper"

class Assistant::CapabilityCoverageTest < Minitest::Test
  def test_accepts_one_classification_for_every_route_and_openapi_operation
    catalog = catalog_with(
      "GET /api/v1/targets" => { "classification" => "enabled", "tool" => "list_targets" },
      "GET /api/v1/assistant/settings" => { "classification" => "excluded_governance" }
    )

    assert Assistant::CapabilityCoverage.verify!(
      catalog: catalog,
      route_operations: [ "GET /api/v1/targets", "GET /api/v1/assistant/settings" ],
      openapi_operations: [ "GET /api/v1/targets" ]
    )
  end

  def test_rejects_an_unclassified_api_operation
    catalog = catalog_with(
      "GET /api/v1/targets" => { "classification" => "enabled", "tool" => "list_targets" }
    )

    error = assert_raises(Assistant::CapabilityCoverage::CoverageError) do
      Assistant::CapabilityCoverage.verify!(
        catalog: catalog,
        route_operations: [ "GET /api/v1/targets", "POST /api/v1/targets/import" ],
        openapi_operations: [ "GET /api/v1/targets" ]
      )
    end

    assert_equal "unclassified API operations: POST /api/v1/targets/import", error.message
  end

  def test_rejects_a_classification_for_an_api_operation_that_does_not_exist
    catalog = catalog_with(
      "GET /api/v1/targets" => { "classification" => "enabled", "tool" => "list_targets" },
      "POST /api/v1/targets/import" => { "classification" => "enabled", "tool" => "import_targets" }
    )

    error = assert_raises(Assistant::CapabilityCoverage::CoverageError) do
      Assistant::CapabilityCoverage.verify!(
        catalog: catalog,
        route_operations: [ "GET /api/v1/targets" ],
        openapi_operations: [ "GET /api/v1/targets" ]
      )
    end

    assert_equal "classifications without API operations: POST /api/v1/targets/import", error.message
  end

  def test_normalizes_rails_parameter_paths_to_openapi_parameter_paths
    assert_equal(
      "PATCH /api/v1/vulnerabilities/{id}",
      Assistant::CapabilityCoverage.normalize_operation(
        "PATCH /api/v1/vulnerabilities/:id(.:format)"
      )
    )
  end

  private

  FakeCatalog = Data.define(:api_classifications, :tools)

  def catalog_with(classifications)
    tools = classifications.values.filter_map do |entry|
      next unless entry["tool"]

      { "name" => entry.fetch("tool") }
    end
    FakeCatalog.new(api_classifications: classifications, tools: tools)
  end
end
