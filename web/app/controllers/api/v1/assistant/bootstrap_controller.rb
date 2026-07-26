module Api
  module V1
    module Assistant
      class BootstrapController < BaseController
        def show
          render json: {
            settings: serialize_setting(::Assistant::Setting.instance),
            provider_profiles: ::Assistant::ProviderProfile.order(:name).map do |profile|
              serialize_provider_profile(profile)
            end,
            conversations: current_assistant_user.assistant_conversations
              .includes(:provider_profile).order(updated_at: :desc).map do |conversation|
                serialize_conversation(conversation)
              end
          }
        end
      end
    end
  end
end
