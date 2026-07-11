module Api
  module V1
    module Programs
      # Run-log feed for the Logs tab. Lists every Scope run (all users' — logs
      # are shared operational history); `mine=1` narrows to the current user.
      # `since_id` also re-pulls in-flight rows so their finished state updates.
      class RunsController < Api::V1::BaseController
        def index
          rows = ScopeRun.all
          rows = rows.where(user_id: Current.user.id) if params[:mine].present?
          rows = rows.where(kind: params[:kind]) if params[:kind].present?
          rows = rows.where(platform: params[:platform]) if params[:platform].present?
          rows = rows.where(success: params[:status] == "ok") if params[:status].present?

          if params[:since_id].present?
            rows = rows.where("id > ? OR finished_at IS NULL", params[:since_id])
          elsif params[:before_id].present?
            rows = rows.where("id < ?", params[:before_id])
          end

          rows = rows.recent.limit(clamped_limit)
          render json: { runs: rows.map(&:as_log_json) }
        end

        def show
          run = ScopeRun.find_by(id: params[:id])
          return render_not_found unless run
          # A user's own runs are private to them; system runs (no user) are
          # visible to any authenticated operator.
          return render_not_found if run.user_id && run.user_id != Current.user.id

          render json: run.as_log_json
        end
      end
    end
  end
end
