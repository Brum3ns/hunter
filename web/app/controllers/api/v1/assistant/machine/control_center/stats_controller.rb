module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          class StatsController < ReadController
            def show
              reservation = authorize_tool!(
                "get_control_center_stats", scope: "control_center_jobs_read"
              )
              detail_response(
                reservation, key: :stats, value: ::ControlCenter::JobStats.dashboard
              )
            end
          end
        end
      end
    end
  end
end
