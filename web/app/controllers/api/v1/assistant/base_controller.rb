module Api
  module V1
    module Assistant
      class BaseController < Api::V1::BaseController
        skip_before_action :authenticate_api!
        skip_before_action :authorize_scope!

        prepend_before_action :reject_authorization_header!
        before_action :authenticate_session_only!
        before_action :require_assistant_admin!

        private

        def reject_authorization_header!
          render_session_required if request.authorization.present?
        end

        def authenticate_session_only!
          return if resume_session && Current.session&.user

          render_session_required
        end

        def require_assistant_admin!
          return if ::Assistant::AdminPolicy.allowed?(Current.session&.user)

          render json: { error: "assistant_admin_required" }, status: :forbidden
        end

        def require_assistant_enabled!
          return if ::Assistant::Config.enabled? && ::Assistant::Setting.instance.assistant_enabled?

          render json: { error: "assistant_disabled" }, status: :service_unavailable
        end

        def require_conversation_management_enabled!
          return if ::Assistant::Setting.instance.conversation_management_enabled?

          render json: { error: "conversation_management_disabled" },
            status: :service_unavailable
        end

        def exact_request_body!(keys)
          attributes = request.request_parameters
          return attributes if attributes.respond_to?(:keys) && attributes.keys.sort == keys.sort

          raise ActionController::ParameterMissing, keys.join(", ")
        end

        def current_assistant_user
          Current.session.user
        end

        def render_session_required
          render json: { error: "session_required" }, status: :unauthorized
        end

        def render_validation_errors(record)
          render json: { error: "validation_failed", errors: record.errors.to_hash },
            status: :unprocessable_entity
        end

        def serialize_provider_profile(profile)
          {
            id: profile.id,
            name: profile.name,
            catalog_slug: profile.catalog_slug,
            provider: profile.provider,
            model: profile.model,
            enabled: profile.enabled?,
            input_limit: profile.input_limit,
            output_limit: profile.output_limit,
            tool_call_limit: profile.tool_call_limit,
            retention_posture: profile.retention_posture,
            reviewed_at: profile.reviewed_at&.iso8601,
            created_at: profile.created_at&.iso8601,
            updated_at: profile.updated_at&.iso8601
          }
        end

        def serialize_conversation(conversation, messages: false)
          backend = ::Assistant::ChatBackend.slug_for(conversation.provider_profile)
          payload = {
            id: conversation.id,
            status: conversation.status,
            title: conversation.title,
            expires_at: conversation.expires_at.iso8601,
            created_at: conversation.created_at.iso8601,
            updated_at: conversation.updated_at.iso8601,
            backend: backend,
            brand: backend && ::Assistant::ChatBackend::BRANDS.fetch(backend),
            legacy: backend.nil?
          }
          if messages
            payload[:messages] = conversation.messages.order(:sequence).map do |message|
              {
                id: message.id,
                turn_id: message.turn_id,
                role: message.role,
                body: message.body,
                sequence: message.sequence,
                created_at: message.created_at.iso8601
              }
            end
            payload[:turns] = conversation.turns.order(:created_at).map do |turn|
              {
                id: turn.id,
                status: turn.status,
                error_code: turn.error_code,
                created_at: turn.created_at.iso8601,
                completed_at: turn.completed_at&.iso8601
              }
            end
            payload[:drafts] = conversation.drafts.order(:id).map do |draft|
              {
                id: draft.id,
                artifact_type: draft.artifact_type,
                name: draft.name,
                validation_status: draft.validation_status,
                validation_version: draft.validation_version,
                updated_at: draft.updated_at.iso8601
              }
            end
          end
          payload
        end

        def serialize_setting(setting)
          state = ::Assistant::Activation.state
          {
            assistant_enabled: setting.assistant_enabled?,
            infrastructure_enabled: state.active,
            effective_enabled: state.active && setting.assistant_enabled?,
            control_center_write_enabled: setting.control_center_write_enabled?,
            conversation_management_enabled: setting.conversation_management_enabled?,
            disabled_reason: disabled_reason_for(setting, state),
            transcript_retention_days: setting.transcript_retention_days,
            audit_retention_days: setting.audit_retention_days,
            disabled_at: setting.disabled_at&.iso8601,
            disabled_by_id: setting.disabled_by_id
          }
        end

        def disabled_reason_for(setting, state)
          return state.reason unless state.active
          return "disabled_by_administrator" unless setting.assistant_enabled?

          nil
        end
      end
    end
  end
end
