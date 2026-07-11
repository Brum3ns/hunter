# web/app/controllers/programs/base_controller.rb
module Programs
  # Base for every controller in the Programs web department. Adding a tab is a
  # one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    # Platforms the Scope tooling fetches from (single source: ScopePlatforms).
    PLATFORMS = ScopePlatforms::ALL

    TABS = [
      { name: "Programs", path: :programs_root_path },
      { name: "Monitor",  path: :programs_monitor_path },
      { name: "Logs",     path: :programs_logs_path }
    ].freeze
  end
end
