module ControlCenter
  # Statistics tab: server-rendered job analytics. A thin pass-through — all
  # aggregation lives in JobStats, which degrades to safe zeros, so this action
  # never needs to guard.
  class StatisticsController < BaseController
    def index
      @stats = JobStats.dashboard
    end
  end
end
