module Api
  module V1
    module Assistant
      class SettingsController < BaseController
        def show
          render json: serialize_setting(::Assistant::Setting.instance)
        end

        def update
          setting = ::Assistant::Setting.instance
          attributes = settings_params
          enabled = if attributes.key?(:assistant_enabled)
            ActiveModel::Type::Boolean.new.cast(attributes[:assistant_enabled])
          end
          identity_missing = false

          ::Assistant::Setting.transaction do
            setting.lock!
            if enabled && !::Assistant::ServiceIdentity.lock
                .where(role: "mcp_reader", enabled: true).first
              identity_missing = true
              raise ActiveRecord::Rollback
            end
            setting.update!(attributes.except(:assistant_enabled))
            if attributes.key?(:assistant_enabled)
              if enabled
                setting.enable!
              else
                ::Assistant::KillSwitch.disable!(user: current_assistant_user)
              end
            end
          end
          if identity_missing
            return render json: { error: "assistant_service_identity_required" },
              status: :unprocessable_entity
          end

          render json: serialize_setting(setting.reload)
        rescue ActiveRecord::RecordInvalid => error
          render_validation_errors(error.record)
        end

        private

        def settings_params
          params.require(:settings).permit(
            :assistant_enabled,
            :transcript_retention_days,
            :audit_retention_days
          ).to_h.symbolize_keys
        end
      end
    end
  end
end
