module Vulnerabilities
  # Statistics tab: charts summarizing every vulnerability. A thin pass-through —
  # all the counting/bucketing lives in Vulnerabilities::Stats, which degrades to
  # safe zeros when Mongo is unreachable, so this action never needs to guard.
  class StatisticsController < BaseController
    def index
      @stats = Stats.dashboard
    end
  end
end
