module Sitemap
  # Renders one endpoint's detail into the shared `sitemap_detail` Turbo Frame.
  class EndpointsController < BaseController
    def show
      @endpoint = Sitemap::Endpoint.active.find_by(id: params[:id])
      return head :not_found unless @endpoint

      render :show
    end
  end
end
