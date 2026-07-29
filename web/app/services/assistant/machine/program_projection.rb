module Assistant
  module Machine
    # Bounded, redaction-safe field allowlist the Assistant may read from a
    # Program. Never returns the raw Program#data hash. Excludes bloat/infra
    # fields (rules_html, account_access_html, qualifying/non_qualifying
    # vulns, the free-text description, restricted/vpn ip lists, the
    # required user agent) and never joins per-user favorite/trash/view
    # state (the machine path has no Current.user). The key sets here are a
    # contract with the MCP programs module's closed output validators
    # (assistant/mcp/internal/modules/programs/module.go) — change both
    # together.
    module ProgramProjection
      module_function

      def summary(program)
        {
          "sid" => program.sid,
          "name" => program.name,
          "platform" => program.platform,
          "public" => program.public?,
          "bounty_range" => program.bounty_range
        }
      end

      def full(program)
        summary(program).merge(
          "slug" => program.slug,
          "url" => program.url,
          "vdp" => program.vdp?,
          "bounty" => program.bounty?,
          "bounty_min" => program.bounty_min,
          "bounty_max" => program.bounty_max,
          "currency" => program.currency,
          "reward_avg" => program.reward_avg,
          "reward_max" => program.reward_max,
          "report_count" => program.report_count,
          "reports_24h" => program.reports_24h,
          "reports_7d" => program.reports_7d,
          "reports_month" => program.reports_month,
          "avg_response_hrs" => program.avg_response_hrs,
          "scope_count" => program.scope_count,
          "collaboration" => program.collaboration?,
          "tags" => program.tags,
          "languages" => program.languages,
          "scope" => trim_scope(program.scope),
          "out_of_scope" => trim_scope(program.out_of_scope)
        )
      end

      def trim_scope(entries)
        Array(entries).map { |s| { "asset" => s["asset"], "type" => s["type"] } }
      end
    end
  end
end
