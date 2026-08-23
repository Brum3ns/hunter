namespace :assistant do
  namespace :capabilities do
    desc "Verify the reviewed MCP catalog covers every Rails/OpenAPI API operation"
    task verify: :environment do
      catalog = Assistant::CapabilityCatalog.load
      operations = (
        Assistant::CapabilityCoverage.route_operations +
        Assistant::CapabilityCoverage.openapi_operations
      ).uniq

      Assistant::CapabilityCoverage.verify!(
        catalog: catalog,
        route_operations: Assistant::CapabilityCoverage.route_operations,
        openapi_operations: Assistant::CapabilityCoverage.openapi_operations
      )

      puts "Verified #{operations.length} API operations and #{catalog.tools.length} MCP tools."
    end
  end
end
