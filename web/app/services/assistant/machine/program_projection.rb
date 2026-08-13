module Assistant
  module Machine
    # Bounded, redaction-safe field allowlist the Assistant may read from a
    # Program. Never returns the raw Program#data hash or rendered HTML. Rich
    # plain-text policy, scope, reward, and access data is sanitized before it
    # crosses the Assistant boundary. Personal favorite/trash/view state is
    # resolved only for the human user bound to the turn grant. The key sets here are a
    # contract with the MCP programs module's closed output validators
    # (assistant/mcp/internal/modules/programs/module.go) — change both
    # together.
    module ProgramProjection
      module_function

	  State = Data.define(:favorite_sids, :trash_sids, :viewed_at_by_sid)

	  def state_for(user, sids)
		ids = Array(sids).map(&:to_s).uniq
		views = user.program_views.where(program_sid: ids).pluck(:program_sid, :viewed_at).to_h
		State.new(
		  favorite_sids: user.favorite_sids,
		  trash_sids: user.trash_sids,
		  viewed_at_by_sid: views
		)
	  end

      def summary(program, state:)
        {
          "sid" => program.sid,
          "name" => program.name,
          "platform" => program.platform,
          "public" => program.public?,
		  "bounty_range" => program.bounty_range,
		  "favorited" => state.favorite_sids.include?(program.sid),
		  "trashed" => state.trash_sids.include?(program.sid),
		  "last_viewed_at" => state.viewed_at_by_sid[program.sid]
        }
      end

      def full(program, state:)
        summary(program, state: state).merge(
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
		  "date" => program.date,
		  "status" => program.status,
		  "description" => safe_text(program.description).value,
		  "description_redacted" => safe_text(program.description).redacted,
		  "organization" => organization(program.organization),
		  "reward_grid" => reward_grid(program.reward_grid),
		  "hall_of_fame" => program.hall_of_fame?,
		  "hacktivity" => program.hacktivity?,
		  "rules" => safe_text(program.policy&.dig("rules")).value,
		  "rules_redacted" => safe_text(program.policy&.dig("rules")).redacted,
		  "qualifying_vulnerabilities" => safe_list(program.qualifying_vulns),
		  "non_qualifying_vulnerabilities" => safe_list(program.non_qualifying_vulns),
		  "account_access" => safe_text(program.policy&.dig("account_access")).value,
		  "account_access_redacted" => safe_text(program.policy&.dig("account_access")).redacted,
		  "required_user_agent" => safe_text(program.required_user_agent).value,
		  "restricted_ips" => safe_list(program.restricted_ips),
		  "vpn_active" => program.vpn_active?,
		  "vpn_ips" => safe_list(program.vpn_ips),
          "scope" => trim_scope(program.scope),
          "out_of_scope" => trim_scope(program.out_of_scope)
        )
      end

      def trim_scope(entries)
		Array(entries).first(500).map do |entry|
		  item = entry.is_a?(Hash) ? entry : {}
		  {
			"asset" => safe_text(item["asset"]).value,
			"type" => safe_text(item["type"]).value,
			"type_name" => safe_text(item["type_name"]).value,
			"value" => safe_text(item["value"]).value,
			"bounty" => nullable_boolean(item["bounty"]),
			"inscope" => nullable_boolean(item["inscope"]),
			"report_count" => nonnegative_integer(item["report_count"])
		  }
		end
      end

	  def safe_text(value)
		return Assistant::Machine::SensitiveData::Result.new(value: nil, redacted: false) if value.nil?

		Assistant::Machine::SensitiveData.text(value.to_s)
	  end
	  private_class_method :safe_text

	  def safe_list(values)
		Array(values).first(500).filter_map { |value| safe_text(value).value }
	  end
	  private_class_method :safe_list

	  def organization(value)
		hash = value.is_a?(Hash) ? value : {}
		{
		  "name" => safe_text(hash["name"]).value,
		  "slug" => safe_text(hash["slug"]).value,
		  "description" => safe_text(hash["description"]).value,
		  "currency" => safe_text(hash["currency"]).value
		}
	  end
	  private_class_method :organization

	  def reward_grid(value)
		hash = value.is_a?(Hash) ? value : {}
		%w[low medium high critical].to_h { |severity| [ severity, finite_number(hash[severity]) ] }
	  end
	  private_class_method :reward_grid

	  def nullable_boolean(value)
		value if value == true || value == false
	  end
	  private_class_method :nullable_boolean

	  def nonnegative_integer(value)
		parsed = value.is_a?(Integer) ? value : Integer(value, 10)
		parsed if parsed >= 0
	  rescue ArgumentError, TypeError
		nil
	  end
	  private_class_method :nonnegative_integer

	  def finite_number(value)
		return if value.nil?

		parsed = Float(value)
		parsed if parsed.finite?
	  rescue ArgumentError, TypeError
		nil
	  end
	  private_class_method :finite_number
    end
  end
end
