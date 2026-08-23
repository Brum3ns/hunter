module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            class ExecutorHealthController < ReadController
              ACTIVE_RUN_STATUSES = %w[validating running canceling].freeze

              def show
                reservation = authorize_tool!(
                  "get_ansible_executor_health", scope: "control_center_ansible_runs_read"
                )
                runners = ::Runner.where("kinds @> ARRAY['ansible']::varchar[]")
                active = ::ControlCenter::Ansible::Run.where(
                  status: ACTIVE_RUN_STATUSES, runner_id: runners.select(:id)
                ).distinct.count(:runner_id)
                queued_at = ::ControlCenter::Ansible::Run.queued.minimum(:queued_at)
                complete_machine_response!(reservation, {
                  correlation_id: machine_grant.turn.correlation_id,
                  health: {
                    configured_runners: runners.count, active_runners: active,
                    last_seen_at: runners.maximum(:last_seen_at),
                    oldest_queued_age_seconds: queued_at ? [ (Time.current - queued_at).round, 0 ].max : nil
                  }
                })
              end
            end
          end
        end
      end
    end
  end
end
