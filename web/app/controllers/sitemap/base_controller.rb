module Sitemap
  # Base for every controller in the Sitemap web department.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Sitemap", path: :sitemap_root_path }
    ].freeze
  end
end
