module Api
  module V1
    module Assistant
      class DraftsController < BaseController
        def show
          draft = ::Assistant::Draft.joins(:conversation)
            .where(assistant_conversations: { user_id: current_assistant_user.id })
            .find_by(id: params[:id])
          return render_not_found unless draft

          render json: serialize_draft(draft, ::Assistant::DraftReview.call(draft))
        end

        private

        def serialize_draft(draft, review)
          details = draft.validation_details.to_h.stringify_keys
          {
            id: draft.id,
            conversation_id: draft.conversation_id,
            turn_id: draft.turn_id,
            artifact_type: draft.artifact_type,
            name: draft.name,
            content: draft.content,
            content_digest: draft.content_digest,
            validation: {
              status: draft.validation_status,
              version: draft.validation_version,
              codes: Array(details["codes"]),
              messages: Array(details["messages"])
            },
            destination: review.destination,
            destination_stale: review.destination_stale,
            diff: review.diff,
            diff_digest: review.diff_digest,
            can_save: savable?(draft) && !review.destination_stale,
            created_at: draft.created_at.iso8601,
            updated_at: draft.updated_at.iso8601
          }
        end

        def savable?(draft)
          draft.validation_status == "valid" &&
            draft.validation_version == current_validation_version(draft.artifact_type)
        end

        def current_validation_version(artifact_type)
          case artifact_type
          when "whiterabbit_template"
            ::Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION
          when "ansible_playbook"
            ::Assistant::ValidationDispatcher::VALIDATION_VERSION
          end
        end

      end
    end
  end
end
