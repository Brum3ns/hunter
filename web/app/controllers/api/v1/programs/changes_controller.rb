module Api
  module V1
    module Programs
      # Program-change feed for the Monitor tab. Always scoped to Current.user.
      # `since_id` pulls newer rows (live tail); `before_id` pulls older rows
      # (load more) — mutually exclusive.
      class ChangesController < Api::V1::BaseController
        def index
          rows = ProgramChange.where(user_id: Current.user.id)
          rows = rows.where(platform: params[:platform]) if params[:platform].present?
          rows = rows.where(kind: params[:kind]) if params[:kind].present?
          rows = rows.where(program_sid: params[:sid]) if params[:sid].present?
          rows = rows.where("id > ?", params[:since_id]) if params[:since_id].present?
          rows = rows.where("id < ?", params[:before_id]) if params[:before_id].present?

          rows = rows.recent.limit(clamped_limit)
          render json: { changes: rows.map(&:as_feed_json) }
        end
      end
    end
  end
end
