module Api
  module V1
    module Assistant
      module Machine
        class CapabilitiesController < ReadController
          SAFE_TOOL_KEYS = %w[name module effect scope gate rate_profile idempotency].freeze

          def index
            reservation = authorize_tool!(
              "list_hunter_capabilities", scope: "hunter_capabilities_read"
            )
            settings = ::Assistant::Setting.instance
            catalog = ::Assistant::CapabilityCatalog.load
            tools = catalog.tools.filter_map do |tool|
              decision = ::Assistant::CapabilityPolicy.check(
                tool: tool.fetch("name"), settings: settings
              )
              tool.slice(*SAFE_TOOL_KEYS) if decision.allowed?
            end

            complete_read_response!(reservation, {
              correlation_id: machine_correlation_id,
              authorization_mode: machine_authorization.authorization_mode,
              catalog_version: catalog.version,
              limits: effective_limits,
              tools: tools
            })
          end

          private

          def effective_limits
            {
              calls_per_turn: nil,
              calls_hard_ceiling: nil,
              result_bytes_per_call: ::Assistant::Config.max_result_bytes,
              result_bytes_per_turn: nil,
              effects_per_turn: nil,
              effects_per_hour: ::Assistant::Config.max_effects_per_hour,
              launches_per_turn: nil,
              launches_per_hour: ::Assistant::Config.max_launches_per_hour
            }
          end
        end
      end
    end
  end
end
