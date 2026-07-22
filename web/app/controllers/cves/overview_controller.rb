module Cves
  # The CVE browse page: an ecosystem/package/has_fix/date-filtered, searchable,
  # paginated list. Renders HTML by calling Cves::MongoSource directly (the JSON
  # API is a separate surface over the same service).
  class OverviewController < BaseController
    DEFAULT_LIMIT = 50

    def index
      @filter_params = filter_params
      @search = params[:q].presence
      @page   = [params[:page].to_i, 1].max

      docs = Cves::MongoSource.all(
        filters: @filter_params, search: @search, page: @page, limit: DEFAULT_LIMIT
      )
      @cves   = docs.map { |doc| Cve.new(doc) }
      @total  = Cves::MongoSource.count(filters: @filter_params, search: @search)
      @limit  = DEFAULT_LIMIT
      @facets = Cves::MongoSource.ecosystem_facets
    end

    private

    def filter_params
      params.permit(:ecosystem, :package, :has_fix, :published_after, :modified_after)
            .to_h.reject { |_, v| v.blank? }
    end
  end
end
