module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated targets browsing for the Assistant.
        # Delegates to the same Targets::MongoSource the web department uses and
        # returns only the bounded TargetProjection allowlist.
        class TargetsController < ReadController
          MAX_LIMIT = 50

          def index
            reservation = authorize_tool!("list_targets", scope: "targets_read")
            parsed = ::Targets::SearchParser.call(params[:q])
            filters = params.permit(:program, :status).to_h
            page = [ params[:page].to_i, 1 ].max
            limit = params[:limit].blank? ? MAX_LIMIT : params[:limit].to_i.clamp(1, MAX_LIMIT)

            docs = ::Targets::MongoSource.all(
              filters: filters, search: parsed.free_text.presence, expression: parsed.expression,
              page: page, limit: limit
            )
            count = ::Targets::MongoSource.count(
              filters: filters, search: parsed.free_text.presence, expression: parsed.expression
            )

            list_response(
              reservation, count: count, page: page, limit: limit,
              items: docs.map { |doc| ::Assistant::Machine::TargetProjection.summary(::Target.new(doc)) }
            )
          end

          def show
            reservation = authorize_tool!("get_target", scope: "targets_read")
            doc = ::Targets::MongoSource.find(params[:id])
            return machine_not_found(reservation) unless doc

            detail_response(
              reservation, key: :target,
              value: ::Assistant::Machine::TargetProjection.full(::Target.new(doc))
            )
          end

          def analyze
            reservation = authorize_tool!("analyze_targets", scope: "targets_read")
            body = exact_machine_body(reservation, %w[q program status])
            return unless body

            parsed = ::Targets::SearchParser.call(body["q"])
            filters = body.slice("program", "status")
            count = ::Targets::MongoSource.count(
              filters: filters, search: parsed.free_text.presence, expression: parsed.expression
            )
            docs = ::Targets::MongoSource.all(
              filters: filters, search: parsed.free_text.presence, expression: parsed.expression,
              page: 1, limit: ::Assistant::Machine::WorkflowAnalysis::MAX_ROWS
            )
            payload = ::Assistant::Machine::WorkflowAnalysis.targets(docs, count: count)
            complete_read_response!(reservation,
              { correlation_id: machine_correlation_id }.merge(payload))
          end
        end
      end
    end
  end
end
