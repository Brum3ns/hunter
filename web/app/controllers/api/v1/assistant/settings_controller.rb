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
          authoring_enabled = if attributes.key?(:control_center_write_enabled)
            ActiveModel::Type::Boolean.new.cast(attributes[:control_center_write_enabled])
          end
          operational_enabled = if attributes.key?(:operational_access_enabled)
            ActiveModel::Type::Boolean.new.cast(attributes[:operational_access_enabled])
          end
          conversation_management_enabled = if attributes.key?(:conversation_management_enabled)
            ActiveModel::Type::Boolean.new.cast(attributes[:conversation_management_enabled])
          end
          identity_missing = false

          ::Assistant::Setting.transaction do
            setting.lock!
            if enabled && !::Assistant::ServiceIdentity.lock
                .where(role: "mcp_reader", enabled: true).first
              identity_missing = true
              raise ActiveRecord::Rollback
            end
            setting.update!(attributes.except(
              :assistant_enabled,
              :operational_access_enabled,
              :control_center_write_enabled,
              :conversation_management_enabled,
              :disabled_capability_tools,
              :disabled_capability_effects,
              :disabled_capability_modules
            ))
            if attributes.key?(:assistant_enabled)
              if enabled
                setting.enable!
              else
                ::Assistant::KillSwitch.disable!(user: current_assistant_user)
              end
            end
            if attributes.key?(:control_center_write_enabled)
              if authoring_enabled
                setting.enable_control_center_write!(user: current_assistant_user)
              else
                setting.disable_control_center_write!(user: current_assistant_user)
              end
            end
            if attributes.key?(:operational_access_enabled)
              if operational_enabled
                setting.enable_operational_access!(user: current_assistant_user)
              else
                setting.disable_operational_access!(user: current_assistant_user)
              end
            end
            if attributes.keys.any? { |key| key.to_s.start_with?("disabled_capability_") }
              setting.update_capability_disables!(
                tools: attributes.fetch(:disabled_capability_tools, setting.disabled_capability_tools),
                effects: attributes.fetch(:disabled_capability_effects, setting.disabled_capability_effects),
                modules: attributes.fetch(:disabled_capability_modules, setting.disabled_capability_modules),
                user: current_assistant_user
              )
            end
            if attributes.key?(:conversation_management_enabled)
              if conversation_management_enabled
                setting.enable_conversation_management!(user: current_assistant_user)
              else
                setting.disable_conversation_management!(user: current_assistant_user)
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
            :operational_access_enabled,
            :control_center_write_enabled,
            :conversation_management_enabled,
            :transcript_retention_days,
            :audit_retention_days,
            disabled_capability_tools: [],
            disabled_capability_effects: [],
            disabled_capability_modules: []
          ).to_h.symbolize_keys
        end
      end
    end
  end
end
