module Sitemap
  # Sitemap keeps its own controllers and data layer while sharing the Target
  # department's web tabs and sidebar state.
  class BaseController < Targets::BaseController
  end
end
