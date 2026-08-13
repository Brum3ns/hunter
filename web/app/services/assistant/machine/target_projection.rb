module Assistant
  module Machine
    # Bounded, redaction-safe field allowlist the Assistant may read from a
    # target. Never returns the raw Mongo document (Target#as_json). The key sets
    # here are a contract with the closed output validators in
    # assistant/mcp/internal/readmodule/validate.go (driven by targets module's
    # SummaryKeys/FullKeys in assistant/mcp/internal/modules/targets/targets.go)
    # — change both together.
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
		  "page_type" => target.page_type,
		  "input" => target.input,
		  "ip" => target.ip,
		  "path" => target.path,
		  "method" => target.verb,
		  "content_length" => target.content_length,
		  "words" => target.words,
		  "lines" => target.lines,
		  "response_time" => target.response_time,
		  "tool" => target.tool,
		  "failed" => target.failed,
		  "phash" => target.phash,
		  "csp_fqdns" => Array(target.csp["fqdn"]),
		  "csp_domains" => Array(target.csp["domains"]),
		  "response_headers" => Assistant::Machine::SensitiveData.response_headers(target.headers)
        )
      end
    end
  end
end
