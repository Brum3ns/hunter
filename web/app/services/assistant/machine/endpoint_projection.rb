module Assistant
  module Machine
    # Bounded, redaction-safe field allowlist the Assistant may read from a
    # crawled sitemap endpoint. Never returns the raw ActiveRecord attributes
    # (excludes target_id, crawl_mongo_id, url_digest). The key sets here are
    # a contract with the MCP sitemap module's closed output validators
    # (assistant/mcp/internal/modules/sitemap/module.go) — change both together.
    #
    # `method` is read via `read_attribute` because `Sitemap::Endpoint#method`
    # is shadowed by `Object#method`.
    module EndpointProjection
      module_function

      def summary(endpoint)
        {
          "id" => endpoint.id,
          "url" => endpoint.url,
          "path" => endpoint.path,
          "method" => endpoint.read_attribute(:method),
          "status_code" => endpoint.status_code
        }
      end

      def full(endpoint)
        summary(endpoint).merge(
          "origin" => endpoint.origin,
          "content_type" => endpoint.content_type,
          "content_length" => endpoint.content_length,
          "first_seen_at" => endpoint.first_seen_at,
          "last_seen_at" => endpoint.last_seen_at,
          "program" => endpoint.target&.program,
          "host" => endpoint.target&.host,
          "scheme" => endpoint.target&.scheme,
          "port" => endpoint.target&.port
        )
      end
    end
  end
end
