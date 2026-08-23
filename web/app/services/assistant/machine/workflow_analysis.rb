module Assistant
  module Machine
    # Dedicated server-side aggregation for the four discovery modules. This
    # keeps a workflow-scale selection inside Hunter and returns only bounded
    # counts to the model.
    module WorkflowAnalysis
      module_function

      MAX_ROWS = 10_000
      MAX_GROUPS = 100

      def targets(docs, count:)
        {
          count: count,
          analyzed_count: docs.length,
          truncated: count > docs.length,
          technology_counts: counts(docs.flat_map { |doc| Array(doc["tech"]) }),
          status_counts: counts(docs.map { |doc| doc.dig("http", "status_code") }),
          program_counts: counts(docs.map { |doc| doc.dig("metadata", "program") }),
          webserver_counts: counts(docs.map { |doc| doc.dig("http", "webserver") })
        }
      end

      def endpoints(rows, count:)
        {
          count: count,
          analyzed_count: rows.length,
          truncated: count > rows.length,
          method_counts: counts(rows.map { |row| row.read_attribute(:method) }),
          status_counts: counts(rows.map(&:status_code)),
          content_type_counts: counts(rows.map(&:content_type)),
          origin_counts: counts(rows.map(&:origin))
        }
      end

      def programs(programs, count:)
        {
          count: count,
          analyzed_count: programs.length,
          truncated: count > programs.length,
          platform_counts: counts(programs.map(&:platform)),
          status_counts: counts(programs.map(&:status)),
          bounty_counts: counts(programs.map { |program| program.bounty? ? "bounty" : "vdp" }),
          tag_counts: counts(programs.flat_map { |program| Array(program.tags) })
        }
      end

      def cves(cves, count:)
        {
          count: count,
          analyzed_count: cves.length,
          truncated: count > cves.length,
          severity_counts: counts(cves.map(&:severity_level)),
          ecosystem_counts: counts(cves.flat_map { |cve| Array(cve.ecosystems) }),
          language_counts: counts(cves.flat_map { |cve| Array(cve.languages) }),
          fix_counts: counts(cves.map { |cve| cve.has_fix ? "fixed" : "unfixed" })
        }
      end

      def vulnerabilities(vulnerabilities, count:)
        {
          count: count,
          analyzed_count: vulnerabilities.length,
          truncated: count > vulnerabilities.length,
          severity_counts: counts(vulnerabilities.map { |vulnerability| vulnerability.finding["severity"] }),
          status_counts: counts(vulnerabilities.map { |vulnerability| vulnerability.report["status"] }),
          program_counts: counts(vulnerabilities.map { |vulnerability| vulnerability.metadata["program"] }),
          type_counts: counts(vulnerabilities.map { |vulnerability| vulnerability.finding["type"] })
        }
      end

      def templates(templates, count:)
        {
          count: count, analyzed_count: templates.length, truncated: count > templates.length,
          kind_counts: counts(templates.map(&:kind)),
          tag_counts: counts(templates.flat_map { |template| Array(template.tags) }),
          creator_counts: counts(templates.map(&:created_by))
        }
      end

      def jobs(jobs, count:)
        {
          count: count, analyzed_count: jobs.length, truncated: count > jobs.length,
          status_counts: counts(jobs.map(&:status)),
          template_counts: counts(jobs.map(&:template_name)),
          queue_counts: counts(jobs.map(&:queue_name))
        }
      end

      def ansible_runs(groups, count:)
        {
          count: count, analyzed_count: groups.length, truncated: count > groups.length,
          status_counts: counts(groups.map(&:status)),
          execution_mode_counts: counts(groups.map(&:execution_mode)),
          failure_policy_counts: counts(groups.map(&:failure_policy)),
          inventory_counts: counts(groups.map(&:inventory_id)),
          credential_counts: counts(groups.map(&:credential_id))
        }
      end

      def playbooks(playbooks, count:)
        {
          count: count, analyzed_count: playbooks.length, truncated: count > playbooks.length,
          creator_counts: counts(playbooks.map { |playbook| playbook.created_by&.username }),
          variable_set_counts: counts(playbooks.flat_map(&:variable_set_ids)),
          module_counts: counts(playbooks.flat_map { |playbook| ansible_modules(playbook.yaml_content) })
        }
      end

      def ansible_modules(yaml)
        yaml.to_s.scan(/^\s+(ansible\.[a-z0-9_.]+):\s*$/i).flatten
      end
      private_class_method :ansible_modules

      def counts(values)
        values.filter_map do |value|
          next if value.nil?

          safe = Assistant::Machine::SensitiveData.text(value.to_s, max_bytes: 512).value
          safe.presence
        end.tally.sort_by { |value, count| [ -count, value ] }.first(MAX_GROUPS).map do |value, count|
          { value: value, count: count }
        end
      end
      private_class_method :counts
    end
  end
end
