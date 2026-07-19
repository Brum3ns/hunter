module Sitemap
  # Turns filter params into a single endpoint scope, shared by the origin-count
  # query (#index) and the per-origin tree build (#tree) so both apply identical
  # endpoint criteria. Target-level filters (program/scheme/host) are applied on
  # the Target scope by the controller, not here.
  module EndpointFilter
    module_function

    STATUS_RANGES = { "2" => 200..299, "3" => 300..399, "4" => 400..499, "5" => 500..599 }.freeze
    TRUTHY = %w[1 true on yes].freeze

    def apply(scope, params)
      params ||= {}
      scope = by_methods(scope, params[:methods])
      scope = by_status(scope, params[:status])
      scope = by_path(scope, params[:path])
      scope = by_has_query(scope, params[:has_query])
      scope = by_content_type(scope, params[:content_type])
      scope
    end

    def by_methods(scope, methods)
      list = Array(methods).map { |m| m.to_s.strip.upcase }.reject(&:empty?)
      list.empty? ? scope : scope.where(method: list)
    end
    private_class_method :by_methods

    def by_status(scope, families)
      fams = Array(families).map(&:to_s).select { |f| STATUS_RANGES.key?(f) }
      return scope if fams.empty?
      fams.map { |f| scope.where(status_code: STATUS_RANGES[f]) }.reduce(:or)
    end
    private_class_method :by_status

    def by_path(scope, path)
      return scope if path.to_s.strip.empty?
      scope.where("path ILIKE ?", "%#{Sitemap::Endpoint.sanitize_sql_like(path.to_s.strip)}%")
    end
    private_class_method :by_path

    def by_has_query(scope, flag)
      TRUTHY.include?(flag.to_s.downcase) ? scope.where("url LIKE ?", "%?%") : scope
    end
    private_class_method :by_has_query

    def by_content_type(scope, ctype)
      return scope if ctype.to_s.strip.empty?
      scope.where("content_type ILIKE ?", "%#{Sitemap::Endpoint.sanitize_sql_like(ctype.to_s.strip)}%")
    end
    private_class_method :by_content_type
  end
end
