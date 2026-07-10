module Vulnerabilities
  # Serves a single vulnerability's full detail into the right-side drawer. The
  # response is a Turbo Frame ("vuln_panel") the findings list swaps in place;
  # a direct visit still renders inside the app layout as a graceful fallback.
  class DetailsController < BaseController
    def show
      doc = MongoSource.find(params[:id])
      return head :not_found unless doc

      @finding = ::Vulnerability.new(doc)
    end
  end
end
