module Assistant
  module Grants
    class Issuer
      TOOLS = %w[
        get_selected_context
        get_artifact_example
        get_authoring_policy
        validate_whiterabbit_draft
        validate_ansible_draft
        get_validation_result
        list_targets
        get_target
        list_cves
        get_cve
        list_vulnerabilities
        get_vulnerability
        list_endpoints
        get_endpoint
        list_programs
        get_program
        list_templates
        get_template
        list_jobs
        get_job
        list_playbooks
        get_playbook
        list_run_groups
        get_run_group
        get_run
        list_run_events
      ].freeze

      class << self
        def call(turn:, resources:, tools:)
          normalized_resources = normalize_resources(resources)
          normalized_tools = normalize_tools(tools)
          raw = SecureRandom.urlsafe_base64(32)
          profile_limit = turn.provider_profile.tool_call_limit

          Assistant::TurnGrant.create!(
            user: turn.user,
            conversation: turn.conversation,
            turn: turn,
            provider_profile: turn.provider_profile,
            token_digest: Assistant::TurnGrant.digest(raw),
            resources: normalized_resources,
            tools: normalized_tools,
            read_scopes: Assistant::TurnGrant::READ_SCOPES,
            expires_at: Assistant::Config.grant_ttl.from_now,
            max_calls: [ profile_limit, Assistant::Config.max_tool_calls ].min,
            max_result_bytes: Assistant::Config.max_result_bytes,
            max_total_bytes: Assistant::Config.max_total_bytes
          )
          raw
        end

        private

        def normalize_resources(resources)
          normalized = Array(resources).map do |resource|
            attributes = resource.to_h.stringify_keys
            raise ArgumentError, "resource requires exactly type and id" unless
              attributes.keys.sort == %w[id type]

            type = attributes.fetch("type").to_s
            id = attributes.fetch("id").to_s
            raise ArgumentError, "unsupported resource type" unless
              Assistant::ContextReference::RESOURCE_TYPES.include?(type)
            raise ArgumentError, "resource id is required" if id.blank?

            { "type" => type, "id" => id }
          end
          raise ArgumentError, "too many resources" if normalized.length > Assistant::Config.max_records

          normalized.uniq
        end

        def normalize_tools(tools)
          normalized = Array(tools).map(&:to_s).uniq
          unknown = normalized - TOOLS
          raise ArgumentError, "unsupported tools: #{unknown.join(', ')}" if unknown.any?
          raise ArgumentError, "at least one tool is required" if normalized.empty?

          normalized
        end
      end
    end
  end
end
