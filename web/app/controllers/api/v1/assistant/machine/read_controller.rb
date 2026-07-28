module Api
  module V1
    module Assistant
      module Machine
        # Shared behavior for every read-only machine tool controller: pagination
        # clamps and the {correlation_id, ...} envelope. Auth/scope/budget come
        # from BaseController. Subclasses supply only their read source + projection.
        class ReadController < BaseController
          private

          def machine_page
            [ params[:page].to_i, 1 ].max
          end

          def machine_limit(max)
            return max if params[:limit].blank?

            params[:limit].to_i.clamp(1, max)
          end

          def list_response(reservation, count:, page:, limit:, items:)
            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              count: count, page: page, limit: limit, items: items
            })
          end

          def detail_response(reservation, key:, value:)
            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              key => value
            })
          end

          def machine_not_found(reservation)
            reservation.fail!
            render json: { error: "not_found" }, status: :not_found
          end
        end
      end
    end
  end
end
