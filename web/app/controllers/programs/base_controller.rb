# web/app/controllers/programs/base_controller.rb
module Programs
  # Base for every controller in the Programs web department. Adding a tab is a
  # one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Programs", path: :programs_root_path }
    ].freeze
  end
end
