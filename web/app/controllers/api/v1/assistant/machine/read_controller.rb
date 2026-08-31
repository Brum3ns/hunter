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
            complete_read_response!(reservation, {
              correlation_id: machine_correlation_id,
              count: count, page: page, limit: limit, items: items
            })
          end

          def detail_response(reservation, key:, value:)
            complete_read_response!(reservation, {
              correlation_id: machine_correlation_id,
              key => value
            })
          end

          def machine_not_found(reservation)
            reservation.fail!
            render json: { error: "not_found" }, status: :not_found
          end

          def complete_read_response!(reservation, payload)
            sanitized = ::Assistant::Machine::SensitiveData.payload(payload)
            residual = sanitized.value && ::Assistant::Context::SecretDetector.detect(
              sanitized.value,
              max_string_bytes: ::Assistant::Machine::SensitiveData::MAX_PAYLOAD_TEXT_BYTES
            )
            if sanitized.value.nil? || residual
              reservation.fail!
              return render json: { error: "tool_response_rejected" }, status: :forbidden
            end

            complete_machine_response!(reservation, sanitized.value)
          end
        end
      end
    end
  end
end
