module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          class HealthController < ReadController
            def show
              reservation = authorize_tool!(
                "get_control_center_health", scope: "control_center_jobs_read"
              )
              source = ::ControlCenter::Standalone.health
              health = %i[rabbitmq mongo].to_h do |name|
                value = source[name] || source[name.to_s] || {}
                [ name, { ok: value[:ok] == true || value["ok"] == true } ]
              end
              detail_response(reservation, key: :health, value: health)
            end
          end
        end
      end
    end
  end
end
