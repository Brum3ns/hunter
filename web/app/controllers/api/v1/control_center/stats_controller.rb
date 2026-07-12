module Api
  module V1
    module ControlCenter
      # Job analytics for external clients — the same data the Statistics tab
      # renders. JobStats degrades to zeros on error, so this never guards.
      class StatsController < BaseController
        def show
          render json: ::ControlCenter::JobStats.dashboard
        end
      end
    end
  end
end
