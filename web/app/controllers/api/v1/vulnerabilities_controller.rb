module Api
  module V1
    # Vulnerabilities API — full CRUD over the MongoDB collection Raily writes.
    # No document-shape validation this pass; any well-formed JSON is accepted.
    class VulnerabilitiesController < BaseController
      # GET /api/v1/vulnerabilities
      def index
        filters = filter_params
        search = params[:q].presence
        page = pagination_page
        limit = clamped_limit

        docs = Vulnerabilities::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
        render json: {
          count: Vulnerabilities::MongoSource.count(filters: filters, search: search),
          page: page,
          limit: limit,
          vulnerabilities: docs.map { |doc| serialize(doc) }
        }
      end

      # GET /api/v1/vulnerabilities/:id
      def show
        doc = Vulnerabilities::MongoSource.find(params[:id])
        return render_not_found unless doc

        render json: serialize(doc)
      end

      # POST /api/v1/vulnerabilities
      def create
        id = Vulnerabilities::MongoSource.create(document_params)
        render json: { id: id }, status: :created
      end

      # PATCH/PUT /api/v1/vulnerabilities/:id
      def update
        doc = Vulnerabilities::MongoSource.update(params[:id], document_params)
        return render_not_found unless doc

        render json: serialize(doc)
      end

      # DELETE /api/v1/vulnerabilities/:id
      def destroy
        return head(:no_content) if Vulnerabilities::MongoSource.delete(params[:id])

        render_not_found
      end

      private

      def filter_params
        params.permit(:program, :severity, :status, :tool).to_h
      end

      # The whole JSON body, minus routing/id noise. No validation this pass.
      def document_params
        params.except(:controller, :action, :format, :id, :vulnerability).permit!.to_h
      end

      def serialize(doc)
        Vulnerability.new(doc).as_json
      end
    end
  end
end
