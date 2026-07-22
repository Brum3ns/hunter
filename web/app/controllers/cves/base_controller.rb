module Cves
  # Base for every controller in the CVE web department. Adding a tab is a
  # one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "CVEs", path: :cves_root_path }
    ].freeze
  end
end
