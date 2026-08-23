module Assistant
  module Grants
    class Issuer
      LEGACY_TOOLS = %w[
        get_selected_context
        get_artifact_example
        get_authoring_policy
        validate_whiterabbit_draft
        validate_ansible_draft
        get_validation_result
      ].freeze

      CATALOG = Assistant::CapabilityCatalog.load
      CATALOG_TOOLS = CATALOG.tools.index_by { |tool| tool.fetch("name") }.freeze
      CHAT_TOOLS = CATALOG.tools.map { |tool| tool.fetch("name") }.freeze
      CHAT_READ_TOOLS = CATALOG.tools.filter_map do |tool|
        tool.fetch("name") if Assistant::TurnGrant::READ_EFFECTS.include?(tool.fetch("effect"))
      end.freeze
      CHAT_CREATE_TOOLS = CATALOG.tools.filter_map do |tool|
        tool.fetch("name") if tool.fetch("effect") == "create"
      end.freeze
      CHAT_EDIT_TOOLS = CATALOG.tools.filter_map do |tool|
        tool.fetch("name") if tool.fetch("effect") == "update"
      end.freeze
      AUTHORING_TOOLS = CATALOG.tools.filter_map do |tool|
        tool.fetch("name") unless Assistant::TurnGrant::READ_EFFECTS.include?(tool.fetch("effect"))
      end.freeze
      TOOLS = (LEGACY_TOOLS + CHAT_TOOLS).freeze

      class << self
        def call(turn:, resources:, tools:)
          normalized_resources = normalize_resources(resources)
          normalized_tools = normalize_tools(tools)
          normalized_tools = enabled_tools(normalized_tools)
          capabilities = normalized_tools.filter_map { |tool| CATALOG_TOOLS[tool] }
          read_scopes = capabilities.filter_map do |tool|
            tool.fetch("scope") if Assistant::TurnGrant::READ_EFFECTS.include?(tool.fetch("effect"))
          end.uniq.sort
          write_scopes = capabilities.filter_map do |tool|
            tool.fetch("scope") unless Assistant::TurnGrant::READ_EFFECTS.include?(tool.fetch("effect"))
          end.uniq.sort
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
            read_scopes: read_scopes,
            write_scopes: write_scopes,
            expires_at: Assistant::Config.grant_ttl.from_now,
            max_calls: [ profile_limit, Assistant::Config.max_tool_calls ].min,
            max_result_bytes: Assistant::Config.max_result_bytes,
            max_total_bytes: Assistant::Config.max_total_bytes
          )
          raw
        end

        private

        def enabled_tools(tools)
          settings = Assistant::Setting.instance
          tools.select do |tool|
            LEGACY_TOOLS.include?(tool) ||
              Assistant::CapabilityPolicy.check(tool: tool, settings: settings).allowed?
          end
        end

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
