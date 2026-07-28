module Assistant
  module Machine
    # Bounded, redaction-safe field allowlist the Assistant may read from a CVE.
    # Never returns the raw Cve#as_json. The key sets here are a contract with
    # the MCP cves module's closed output validators
    # (assistant/mcp/internal/modules/cves/module.go) — change both together.
    module CveProjection
      module_function

      def summary(cve)
        {
          "id" => cve.id,
          "summary" => cve.summary,
          "severity_level" => cve.severity_level,
          "severity_score" => cve.severity_score,
          "has_fix" => cve.has_fix,
          "modified" => cve.modified
        }
      end

      def full(cve)
        summary(cve).merge(
          "details" => cve.details,
          "aliases" => Array(cve.aliases),
          "published" => cve.published,
          "withdrawn" => cve.withdrawn,
          "cwe_ids" => Array(cve.cwe_ids),
          "ecosystems" => Array(cve.ecosystems),
          "languages" => Array(cve.languages),
          "vendors" => Array(cve.vendors),
          "tags" => Array(cve.tags),
          "affected" => Array(cve.affected),
          "references" => Array(cve.references),
          "chain" => cve.chain,
          "osv_id" => cve.osv_id,
          "first_seen_at" => cve.first_seen_at,
          "last_synced_at" => cve.last_synced_at
        )
      end
    end
  end
end
