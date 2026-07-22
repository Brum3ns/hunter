module Cves
  # Serves one CVE's full detail into the right-side "cve_panel" drawer (a Turbo
  # Frame the list swaps in place). A direct visit renders inside the app layout
  # as a graceful fallback.
  class DetailsController < BaseController
    def show
      doc = Cves::MongoSource.find(params[:id])
      return head :not_found unless doc

      @cve = Cve.new(doc)
    end
  end
end
