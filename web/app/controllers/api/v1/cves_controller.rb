module Api
  module V1
    # CVE tracking module API — read-only over the MongoDB `cves` collection.
    # `index`/`show` serve the browse UI; `new` is the LLM-facing "new since"
    # feed. A CVE-scoped token's saved `cve_filter` supplies defaults that
    # request params override per-field. `?fields=core` returns the compact
    # serialization for small LLM context.
    class CvesController < BaseController
      api_scope :cves

      FILTER_PARAMS = %i[ecosystem package language vendor cwe tag has_fix
                         min_severity published_after modified_after].freeze

      # Maps saved-filter (plural) keys to the singular filter keys MongoSource
      # understands; "keyword" maps to search.
      SAVED_TO_FILTER = {
        "ecosystems" => "ecosystem", "packages" => "package",
        "languages" => "language", "vendors" => "vendor",
        "cwe" => "cwe", "tags" => "tag", "min_severity" => "min_severity",
        "has_fix" => "has_fix", "published_after" => "published_after",
        "modified_after" => "modified_after"
      }.freeze

      # GET /api/v1/cves
      def index
        filters = effective_filters
        search  = effective_search
        page    = pagination_page
        limit   = clamped_limit

        docs = Cves::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
        render json: {
          count: Cves::MongoSource.count(filters: filters, search: search),
          page: page,
          limit: limit,
          cves: docs.map { |doc| serialize(doc) }
        }
      end

      # GET /api/v1/cves/:id  (id is a CVE id, e.g. CVE-2024-1234)
      def show
        doc = Cves::MongoSource.find(params[:id])
        return render_not_found unless doc

        render json: Cve.new(doc).as_json
      end

      # GET /api/v1/cves/new?since=<ISO-8601>&since_id=<id>&limit=<n>
      def new
        since    = parse_since(params[:since])
        since_id = params[:since_id].presence
        limit    = clamped_limit
        docs     = Cves::MongoSource.new_since(
          since: since, since_id: since_id, limit: limit,
          filters: effective_filters, search: effective_search
        )
        render json: {
          limit: limit,
          cves: docs.map { |doc| serialize(doc) },
          next_since: docs.last && docs.last["first_seen_at"],
          next_since_id: docs.last && docs.last["id"]
        }
      end

      # GET /api/v1/cves/config — echoes the bearer token's saved filter.
      # Named filter_config because ActionController reserves #config
      # (ActiveSupport::Configurable) and overriding it breaks render.
      def filter_config
        render json: { cve_filter: Current.api_token&.cve_filter || {} }
      end

      private

      def serialize(doc)
        cve = Cve.new(doc)
        params[:fields].to_s == "core" ? cve.as_core_json : cve.as_json
      end

      # Saved filter (translated to MongoSource keys) overlaid with any request
      # filter params that are present.
      def effective_filters
        base = saved_filter_as_mongo
        params.permit(*FILTER_PARAMS).to_h.each { |k, v| base[k] = v if v.present? }
        base
      end

      def effective_search
        params[:q].presence || params[:keyword].presence || saved_filter["keyword"].presence
      end

      def saved_filter
        (Current.api_token&.cve_filter || {}).to_h
      end

      def saved_filter_as_mongo
        saved_filter.each_with_object({}) do |(key, value), out|
          mapped = SAVED_TO_FILTER[key.to_s]
          out[mapped] = value if mapped && value.present?
        end
      end

      def parse_since(value)
        return nil if value.blank?
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
