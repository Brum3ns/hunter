module ControlCenter
  # Base for every controller in the Control Center web department. Adding a tab
  # is a one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Templates", path: :control_center_root_path },
      { name: "Jobs",      path: :control_center_jobs_path }
    ].freeze
  end
end
