module Programs
  # The Logs tab: a table of Scope fetch/CLI runs. Thin shell — the table
  # hydrates from /api/v1/programs/runs and polls in-flight rows to completion
  # (see programs_logs_controller.js).
  class LogsController < BaseController
    def index
      @platforms = PLATFORMS
      @kinds = ScopeRun::KINDS
    end
  end
end
