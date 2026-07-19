module Sitemap
  # The sitemap department: a tree of target origins, each expandable into its
  # crawled-endpoint path tree. #index renders the origin list (top-level
  # folders); #tree lazily renders one origin's full path tree (Task 3).
  class OriginsController < BaseController
    def index
      @q = params[:q].to_s.strip
      scope = Sitemap::Target.active.order(:host, :port)
      if @q.present?
        scope = scope.where("host ILIKE ?", "%#{Sitemap::Target.sanitize_sql_like(@q)}%")
      end
      @targets = scope.to_a
      @counts = Sitemap::Endpoint.active.where(target_id: @targets.map(&:id)).group(:target_id).count
    end
  end
end
