module Sitemap
  # The sitemap department: a tree of target origins, each expandable into its
  # crawled-endpoint path tree. Filters (method, status, path, has-query,
  # content-type plus parsed search via EndpointFilter; program/scheme and
  # min-count here) apply
  # to both the origin list's counts/visibility and each origin's tree.
  class OriginsController < BaseController
    def index
      @q       = params[:q].to_s.strip
      @program = params[:program].presence
      @scheme  = params[:scheme].presence
      raw_min  = params[:min_count]
      @min_count = raw_min.present? ? [ raw_min.to_i, 0 ].max : 1

      targets = Sitemap::Target.active.order(:host, :port)
      targets = targets.where(program: @program) if @program
      targets = targets.where(scheme: @scheme) if @scheme
      candidates = targets.to_a

      endpoint_scope = Sitemap::Endpoint.active.where(target_id: candidates.map(&:id))
      @counts = filtered_endpoints(endpoint_scope).group(:target_id).count
      @targets = candidates.select do |target|
        @counts[target.id].to_i >= @min_count && (@q.blank? || @counts.key?(target.id))
      end

      @programs       = Sitemap::Target.active.distinct.pluck(:program).compact.sort
      @method_options = Sitemap::Endpoint.active.distinct.pluck(:method).compact.sort
      @filter         = endpoint_filter_params.to_h
      @tree_filter    = @filter.dup
      @tree_filter["q"] = @q if @q.present?
    end

    def tree
      @target = Sitemap::Target.active.find_by(id: params[:id])
      return head :not_found unless @target

      @nodes = Sitemap::Tree.build(filtered_endpoints(@target.endpoints.active))
      render :tree
    end

    private

    def filtered_endpoints(scope)
      parsed = Sitemap::SearchParser.call(params[:q])
      Sitemap::EndpointFilter.apply(
        scope,
        endpoint_filter_params,
        free_text: parsed.free_text,
        expression: parsed.expression,
        include_root: params[:include_root]
      )
    end

    def endpoint_filter_params
      params.permit(:path, :has_query, :content_type, :include_root, methods: [], status: [])
    end
  end
end
