module Vulnerabilities
  # Base for every controller in the vulnerability-management web department.
  # Adding a tab to this module is a one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Vulnerabilities", path: :vulnerabilities_root_path }
    ].freeze
  end
end
