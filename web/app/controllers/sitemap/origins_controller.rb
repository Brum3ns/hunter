module Sitemap
  # The sitemap department: a tree of target origins, each expandable into its
  # crawled-endpoint path tree. Filters (method, status, path, has-query,
  # content-type via EndpointFilter; program/scheme/host + min-count here) apply
  # to both the origin list's counts/visibility and each origin's tree.
  class OriginsController < BaseController
    def index
      @q       = params[:q].to_s.strip
      @program = params[:program].presence
      @scheme  = params[:scheme].presence
      raw_min  = params[:min_count]
      @min_count = raw_min.present? ? [raw_min.to_i, 0].max : 1

      targets = Sitemap::Target.active.order(:host, :port)
      targets = targets.where("host ILIKE ?", "%#{Sitemap::Target.sanitize_sql_like(@q)}%") if @q.present?
      targets = targets.where(program: @program) if @program
      targets = targets.where(scheme: @scheme) if @scheme
      candidates = targets.to_a

      @counts = Sitemap::EndpointFilter.apply(Sitemap::Endpoint.active, endpoint_filter_params)
                                       .where(target_id: candidates.map(&:id))
                                       .group(:target_id).count
      @targets = candidates.select { |t| @counts[t.id].to_i >= @min_count }

      @programs       = Sitemap::Target.active.distinct.pluck(:program).compact.sort
      @method_options = Sitemap::Endpoint.active.distinct.pluck(:method).compact.sort
      @filter         = endpoint_filter_params.to_h
    end

    def tree
      @target = Sitemap::Target.active.find_by(id: params[:id])
      return head :not_found unless @target

      @nodes = Sitemap::Tree.build(Sitemap::EndpointFilter.apply(@target.endpoints.active, endpoint_filter_params))
      render :tree
    end

    private

    def endpoint_filter_params
      params.permit(:path, :has_query, :content_type, methods: [], status: [])
    end
  end
end
