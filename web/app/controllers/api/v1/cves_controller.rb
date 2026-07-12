module Api
  module V1
    # CVE tracking module API — read-only over the MongoDB `cves` collection.
    # `index`/`show` serve the browse UI; `new` is the LLM-facing "new since"
    # feed keyed on our first_seen_at ingest stamp.
    class CvesController < BaseController
      FILTER_PARAMS = %i[ecosystem package has_fix published_after modified_after].freeze

      # GET /api/v1/cves
      def index
        filters = params.permit(*FILTER_PARAMS).to_h
        search  = params[:q].presence
        page    = pagination_page
        limit   = clamped_limit

        docs = Cves::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
        render json: {
          count: Cves::MongoSource.count(filters: filters, search: search),
          page: page,
          limit: limit,
          cves: docs.map { |doc| Cve.new(doc).as_json }
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
        docs     = Cves::MongoSource.new_since(since: since, since_id: since_id, limit: limit)
        render json: {
          limit: limit,
          cves: docs.map { |doc| Cve.new(doc).as_json },
          next_since: docs.last && docs.last["first_seen_at"],
          next_since_id: docs.last && docs.last["id"]
        }
      end

      private

      def parse_since(value)
        return nil if value.blank?
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
