module Assistant
  module Machine
    # Bounded, redaction-safe field allowlist the Assistant may read from a
    # target. Never returns the raw Mongo document (Target#as_json). The key sets
    # here are a contract with the MCP targets module's closed output validators
    # (assistant/mcp/internal/modules/targets/output.go) — change both together.
    module TargetProjection
      module_function

      def summary(target)
        {
          "id" => target.id,
          "host" => target.host,
          "program" => target.program,
          "status_code" => target.status_code,
          "title" => target.title
        }
      end

      def full(target)
        summary(target).merge(
          "url" => target.url,
          "status_family" => target.status_family,
          "webserver" => target.webserver,
          "content_type" => target.content_type,
          "port" => target.port,
          "scheme" => target.scheme,
          "tech" => Array(target.tech),
          "seen_at" => target.seen_at,
          "page_type" => target.page_type
        )
      end
    end
  end
end
