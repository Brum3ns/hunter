module Api
  module V1
    module Runner
      # Pull endpoints for runner containers. Authenticated against the Runner
      # machine identity (NOT ApiToken); user tokens are rejected here.
      class JobsController < Api::V1::BaseController
        skip_before_action :authenticate_api!
        before_action :authenticate_runner!

        def claim
          job = ::RunnerJob.claim!(Current.runner)
          return head :no_content unless job

          render json: { id: job.id, kind: job.kind, command: job.command }
        end

        def result
          job = ::RunnerJob.find_by(id: params[:id], runner_id: Current.runner.id, status: "running")
          return render_not_found unless job

          job.record_result!(
            exit_status: params[:exit_status],
            stdout: params[:stdout].to_s,
            stderr: params[:stderr].to_s,
            error: params[:error].presence,
            duration_ms: params[:duration_ms],
            output_truncated: ActiveModel::Type::Boolean.new.cast(params[:output_truncated])
          )
          render json: { ok: true }
        end

        private

        def authenticate_runner!
          runner = ::Runner.authenticate(bearer_token)
          return request_authentication unless runner

          Current.runner = runner
        end
      end
    end
  end
end
