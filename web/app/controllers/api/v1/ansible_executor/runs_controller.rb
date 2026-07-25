module Api
  module V1
    module AnsibleExecutor
      class RunsController < BaseController
        ACTIVE_STATUSES = %w[validating running canceling].freeze

        def claim
          claim = ::ControlCenter::Ansible::RunClaim.call(runner: Current.runner)
          return head :no_content unless claim

          render json: {
            id: claim.run.id,
            run_group_id: claim.run.run_group_id,
            lease: claim.lease,
            lease_expires_at: claim.lease_expires_at,
            payload: claim.payload
          }
        end

        def start
          with_leased_run(statuses: %w[validating running]) do |run|
            run.update!(status: "running", started_at: run.started_at || Time.current) if run.status == "validating"
            render json: run_state(run)
          end
        end

        def heartbeat
          with_leased_run(statuses: ACTIVE_STATUSES) do |run|
            now = Time.current
            run.update!(heartbeat_at: now, lease_expires_at: now + lease_seconds)
            render json: run_state(run)
          end
        end

        def control
          with_leased_run(statuses: ACTIVE_STATUSES) do |run|
            render json: {
              id: run.id,
              status: run.status,
              cancel_requested: run.cancel_requested_at.present? || run.run_group.cancel_requested_at.present?
            }
          end
        end

        def result
          run = find_run
          return render_not_found unless run

          run = ::ControlCenter::Ansible::RunResult.call(
            run:,
            runner: Current.runner,
            lease: lease_token,
            result: result_params
          )
          render json: run_state(run)
        end

        private

        def with_leased_run(statuses:)
          run = find_run
          return render_not_found unless run

          ::ControlCenter::Ansible::Run.transaction do
            run.lock!
            ::ControlCenter::Ansible::LeaseVerifier.verify!(
              run, runner: Current.runner, lease: lease_token, statuses:
            )
            yield run
          end
        end

        def find_run
          ::ControlCenter::Ansible::Run.find_by(id: params[:id])
        end

        def result_params
          params.to_unsafe_h.slice(
            "status", "exit_status", "ok_count", "changed_count", "failed_count",
            "unreachable_count", "error_code", "error_detail"
          )
        end

        def run_state(run)
          {
            id: run.id,
            status: run.status,
            heartbeat_at: run.heartbeat_at,
            lease_expires_at: run.lease_expires_at,
            started_at: run.started_at,
            completed_at: run.completed_at
          }
        end
      end
    end
  end
end
