module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated targets browsing for the Assistant.
        # Delegates to the same Targets::MongoSource the web department uses and
        # returns only the bounded TargetProjection allowlist.
        class TargetsController < BaseController
          MAX_LIMIT = 50

          def index
            reservation = authorize_tool!("list_targets", scope: "targets")
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

            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              count: count,
              page: page,
              limit: limit,
              items: docs.map { |doc| ::Assistant::Machine::TargetProjection.summary(::Target.new(doc)) }
            })
          end

          def show
            reservation = authorize_tool!("get_target", scope: "targets")
            doc = ::Targets::MongoSource.find(params[:id])
            unless doc
              reservation.fail!
              return render json: { error: "not_found" }, status: :not_found
            end

            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              target: ::Assistant::Machine::TargetProjection.full(::Target.new(doc))
            })
          end
        end
      end
    end
  end
end
