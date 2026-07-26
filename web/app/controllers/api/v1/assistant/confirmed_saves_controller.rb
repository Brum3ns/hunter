module Api
  module V1
    module Assistant
      class ConfirmedSavesController < BaseController
        def create
          draft = ::Assistant::Draft.joins(:conversation)
            .where(assistant_conversations: { user_id: current_assistant_user.id })
            .find_by(id: params[:draft_id])
          return render_not_found unless draft

          review = ::Assistant::DraftReview.call(draft)
          confirmation = confirmation_params
          mismatches = confirmation_mismatches(draft, review, confirmation)
          if mismatches.any?
            return render json: { error: "confirmation_mismatch", errors: mismatches },
              status: :unprocessable_entity
          end

          if review.destination_stale
            return render json: { error: "destination_stale", errors: [ "destination_stale" ] },
              status: :conflict
          end

          destination = review.destination_record
          creating = draft.destination_id.blank?
          result = ::Assistant::ConfirmedSave.call(
            draft: draft, user: current_assistant_user, destination: destination
          )
          return render_failure(result) unless result.success?

          render json: { artifact: serialize_artifact(draft, result.record) },
            status: creating ? :created : :ok
        end

        private

        def confirmation_params
          raw = params.require(:confirmation)
          permitted = raw.permit(
            :name, :content_digest, :validation_version, :diff_digest,
            destination: %i[type id lock_version]
          )
          permitted[:destination] = nil if raw.key?(:destination) && raw[:destination].nil?
          permitted[:diff_digest] = nil if raw.key?(:diff_digest) && raw[:diff_digest].nil?
          permitted
        end

        def confirmation_mismatches(draft, review, confirmation)
          mismatches = []
          mismatches << "name_mismatch" unless confirmation[:name].to_s == draft.name
          mismatches << "content_digest_mismatch" unless
            confirmed_digest?(confirmation[:content_digest], draft.content_digest)
          mismatches << "validation_version_mismatch" unless
            confirmation[:validation_version].to_s == draft.validation_version
          mismatches << "diff_digest_mismatch" unless
            confirmation.key?(:diff_digest) && optional_digest_matches?(confirmation[:diff_digest], review.diff_digest)
          mismatches << "destination_mismatch" unless
            confirmation.key?(:destination) &&
              review.destination&.stringify_keys == normalized_destination(confirmation[:destination])
          mismatches
        end

        def optional_digest_matches?(confirmed, actual)
          return confirmed.nil? && actual.nil? if confirmed.nil? || actual.nil?

          confirmed_digest?(confirmed, actual)
        end

        def confirmed_digest?(confirmed, actual)
          confirmed = confirmed.to_s
          actual = actual.to_s
          confirmed.bytesize == actual.bytesize &&
            ActiveSupport::SecurityUtils.secure_compare(confirmed, actual)
        end

        def normalized_destination(value)
          return nil if value.nil?

          value.to_h.stringify_keys.slice("type", "id", "lock_version").transform_values(&:to_s)
        end

        def render_failure(result)
          if result.errors.include?("destination_stale")
            return render json: { error: "destination_stale", errors: result.errors }, status: :conflict
          end

          error = result.errors.any? { |code| code.start_with?("validation_") } ?
            "validation_failed" : "save_failed"
          render json: { error: error, errors: result.errors }, status: :unprocessable_entity
        end

        def serialize_artifact(draft, record)
          content_hash = if draft.artifact_type == "ansible_playbook"
            record.checksum
          else
            Digest::SHA256.hexdigest(::ControlCenter::TemplateRenderer.to_yaml(record))
          end
          {
            type: draft.artifact_type,
            id: record.id,
            lock_version: record.lock_version,
            content_hash: content_hash
          }
        end
      end
    end
  end
end
