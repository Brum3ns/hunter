module Api
  module V1
    module Assistant
      class ContextPreviewsController < BaseController
        class PreviewError < StandardError
          attr_reader :index, :code

          def initialize(index, code)
            @index = index
            @code = code
            super(code)
          end
        end

        before_action :require_assistant_enabled!

        def create
          references = params.require(:references)
          return render_invalid_list unless references.is_a?(Array)
          return render_too_many if references.length > ::Assistant::Config.max_records

          previews = references.each_with_index.map do |reference, index|
            preview(reference, index)
          end
          render json: { previews: previews }
        rescue PreviewError => error
          render json: {
            error: "context_invalid",
            errors: [ { index: error.index, code: error.code } ]
          }, status: :unprocessable_entity
        end

        private

        def preview(reference, index)
          keys = reference.respond_to?(:keys) ? reference.keys.map(&:to_s) : []
          raise PreviewError.new(index, "invalid_reference") unless keys.sort == %w[id type]

          attributes = if reference.respond_to?(:permit)
            reference.permit(:type, :id).to_h
          else
            reference.to_h.stringify_keys.slice("type", "id")
          end

          record = ::Assistant::Context::Resolver.find(
            type: attributes["type"],
            id: attributes["id"],
            user: current_assistant_user
          )
          raise PreviewError.new(index, "not_found") unless record

          ::Assistant::Context::Catalog.serialize!(type: attributes["type"], record: record)
        rescue KeyError
          raise PreviewError.new(index, "unsupported_type")
        rescue ::Assistant::Context::Catalog::UnsafeContentError
          raise PreviewError.new(index, "unsafe_content")
        rescue ::Assistant::Context::Catalog::TooLargeError
          raise PreviewError.new(index, "too_large")
        end

        def render_invalid_list
          render json: { error: "invalid_references" }, status: :bad_request
        end

        def render_too_many
          render json: { error: "too_many_references" }, status: :bad_request
        end
      end
    end
  end
end
