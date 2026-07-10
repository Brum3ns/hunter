module Vulnerabilities
  # Handles inline status edits from the findings table. Writes through the
  # module's MongoSource and answers with a Turbo Stream that swaps the row's
  # status cell. Kept separate from OverviewController so listing stays focused.
  class StatusesController < BaseController
    def update
      doc = MongoSource.update_status(id: params[:id], status: params[:status], user: Current.user)
      return head :not_found unless doc

      @finding = ::Vulnerability.new(doc)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to vulnerabilities_root_path }
      end
    rescue ArgumentError
      head :bad_request
    end
  end
end
