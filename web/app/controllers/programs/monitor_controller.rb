module Programs
  # The Monitor tab: a live feed of detected program changes. The page is a thin
  # shell — the feed hydrates from /api/v1/programs/changes and polls for new
  # rows (see programs_monitor_controller.js).
  class MonitorController < BaseController
    def index
      @platforms = PLATFORMS
      @kinds = ProgramChange::KINDS
    end
  end
end
