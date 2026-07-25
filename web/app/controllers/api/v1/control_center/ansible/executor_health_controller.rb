module Api
  module V1
    module ControlCenter
      module Ansible
        class ExecutorHealthController < Api::V1::BaseController
          api_scope :control_center

          ACTIVE_RUN_STATUSES = %w[validating running canceling].freeze

          def show
            runners = ::Runner.where("kinds @> ARRAY['ansible']::varchar[]")
            active_runners = ::ControlCenter::Ansible::Run
              .where(status: ACTIVE_RUN_STATUSES, runner_id: runners.select(:id))
              .distinct.count(:runner_id)
            oldest_queued_at = ::ControlCenter::Ansible::Run.queued.minimum(:queued_at)

            render json: {
              configured_runners: runners.count,
              active_runners:,
              last_seen_at: runners.maximum(:last_seen_at),
              oldest_queued_age_seconds: oldest_queued_at ? [ (Time.current - oldest_queued_at).round, 0 ].max : nil
            }
          end
        end
      end
    end
  end
end
