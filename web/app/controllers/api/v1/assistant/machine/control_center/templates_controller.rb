module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          # Read-only, grant-and-scope-gated Whiterabbit template browsing for
          # the Assistant. Delegates to the same Postgres read path as the
          # public Api::V1::ControlCenter::TemplatesController and returns
          # only the bounded TemplateProjection allowlist.
          class TemplatesController < ReadController
            MAX_LIMIT = 50
            FILTERS = %i[kind].freeze

            def index
              reservation = authorize_tool!("list_templates", scope: "control_center_templates")
              filters = params.permit(*FILTERS).to_h
              page = machine_page
              limit = machine_limit(MAX_LIMIT)
              scope = filtered_scope(filters)
              count = scope.count
              rows = scope.offset((page - 1) * limit).limit(limit)
              items = rows.map { |template| ::Assistant::Machine::ControlCenter::TemplateProjection.summary(template) }
              list_response(reservation, count: count, page: page, limit: limit, items: items)
            end

            def show
              reservation = authorize_tool!("get_template", scope: "control_center_templates")
              template = ::ControlCenter::Template.find_by(id: params[:id])
              return machine_not_found(reservation) unless template

              detail_response(reservation, key: :template, value: ::Assistant::Machine::ControlCenter::TemplateProjection.full(template))
            end

            private

            def filtered_scope(filters)
              scope = ::ControlCenter::Template.order(:name)
              scope = scope.where(kind: filters[:kind]) if filters[:kind].present?
              scope
            end
          end
        end
      end
    end
  end
end
