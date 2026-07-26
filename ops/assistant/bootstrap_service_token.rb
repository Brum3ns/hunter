# Runs from two different layouts: the repo checkout, where the Rails root is a
# sibling `web/` directory, and the container image, where ops/assistant sits
# inside the Rails root at /app. Resolve whichever exists rather than assuming.
environment = [
  File.expand_path("../../web/config/environment", __dir__),
  File.expand_path("../../config/environment", __dir__)
].find { |candidate| File.exist?("#{candidate}.rb") }

raise "unable to locate the Rails environment from #{__dir__}" unless environment

require environment

Assistant::BootstrapServiceToken.call(
  path: ENV.fetch("ASSISTANT_MCP_TOKEN_PATH", "/run/assistant/secrets/assistant_mcp_hunter_token")
)
