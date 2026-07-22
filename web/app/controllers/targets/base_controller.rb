module Targets
  # Shared web shell for the Target department. Sitemap remains a separate
  # module internally, but appears here as a related Target subsection.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Target", path: :targets_path },
      { name: "Sitemap", path: :targets_sitemap_path }
    ].freeze
  end
end
