require_relative "../../web/config/environment"

Assistant::BootstrapServiceToken.call(
  path: ENV.fetch("ASSISTANT_MCP_TOKEN_PATH", "/run/assistant/secrets/assistant_mcp_hunter_token")
)
