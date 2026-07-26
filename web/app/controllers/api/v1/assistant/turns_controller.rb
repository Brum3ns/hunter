module Api
  module V1
    module Assistant
      class TurnsController < BaseController
        before_action :require_assistant_enabled!, only: :create

        def create
          conversation = current_assistant_user.assistant_conversations.find_by(
            id: params[:conversation_id]
          )
          return render_not_found unless conversation

          turn = ::Assistant::TurnCreator.call(
            conversation: conversation,
            user: current_assistant_user,
            body: params.require(:message),
            context_refs: params.fetch(:contexts, [])
          )
          payload = serialize_turn(turn)
          if turn.status == "interrupted"
            render json: payload.merge(error: "assistant_dispatch_unavailable"),
              status: :service_unavailable
          else
            render json: payload, status: :accepted
          end
        rescue ::Assistant::TurnCreator::InvalidContext => error
          render json: {
            error: "context_invalid", errors: [ { index: error.index, code: error.code } ]
          }, status: :unprocessable_entity
        rescue ::Assistant::TurnCreator::Rejected => error
          render_rejected(error.code)
        rescue ::Assistant::RateLimiter::LimitExceeded => error
          response.headers["Retry-After"] = error.retry_after_seconds.to_s
          render json: { error: error.code }, status: :too_many_requests
        rescue ActiveRecord::RecordInvalid => error
          render_validation_errors(error.record)
        end

        def show
          turn = owned_turn
          return render_not_found unless turn

          turn = ::Assistant::TurnReconciler.call(turn: turn)
          render json: serialize_turn(turn)
        end

        def cancel
          turn = owned_turn
          return render_not_found unless turn

          turn = ::Assistant::TurnCanceler.call(turn: turn, user: current_assistant_user)
          render json: serialize_turn(turn)
        end

        private

        def owned_turn
          ::Assistant::Turn.includes(:messages, :context_references, :drafts)
            .where(user: current_assistant_user).find_by(id: params[:id])
        end

        def serialize_turn(turn)
          {
            id: turn.id,
            conversation_id: turn.conversation_id,
            correlation_id: turn.correlation_id,
            status: turn.status,
            error_code: turn.error_code,
            queued_at: turn.queued_at&.iso8601,
            started_at: turn.started_at&.iso8601,
            completed_at: turn.completed_at&.iso8601,
            created_at: turn.created_at.iso8601,
            context_references: turn.context_references.order(:id).map do |reference|
              {
                type: reference.resource_type,
                id: reference.resource_id,
                label: reference.label,
                serializer_version: reference.serializer_version
              }
            end,
            messages: turn.messages.order(:sequence).map do |message|
              {
                id: message.id,
                role: message.role,
                body: message.body,
                sequence: message.sequence,
                created_at: message.created_at.iso8601
              }
            end,
            drafts: turn.drafts.order(:id).map do |draft|
              {
                id: draft.id,
                artifact_type: draft.artifact_type,
                name: draft.name,
                validation_status: draft.validation_status,
                validation_version: draft.validation_version,
                updated_at: draft.updated_at.iso8601
              }
            end
          }
        end

        def render_rejected(code)
          status = case code
          when "conversation_not_found" then :not_found
          when "assistant_disabled" then :service_unavailable
          else :unprocessable_entity
          end
          render json: { error: code }, status: status
        end
      end
    end
  end
end
