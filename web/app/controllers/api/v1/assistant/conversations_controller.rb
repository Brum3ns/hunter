module Api
  module V1
    module Assistant
      class ConversationsController < BaseController
        before_action :require_assistant_enabled!, only: :create

        def index
          conversations = current_assistant_user.assistant_conversations
            .includes(:provider_profile).order(updated_at: :desc)
          render json: { conversations: conversations.map { |item| serialize_conversation(item) } }
        end

        def show
          conversation = owned_conversation
          return render_not_found unless conversation

          render json: serialize_conversation(conversation, messages: true)
        end

        def create
          profile = ::Assistant::ProviderProfile.find_by(id: params[:provider_profile_id])
          return render_not_found unless profile

          conversation = ::Assistant::Conversation.start!(
            user: current_assistant_user,
            provider_profile: profile
          )
          render json: serialize_conversation(conversation), status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_validation_errors(error.record)
        end

        def destroy
          conversation = owned_conversation
          return render_not_found unless conversation

          conversation.destroy_with_content!
          head :no_content
        end

        private

        def owned_conversation
          current_assistant_user.assistant_conversations
            .includes(:provider_profile, :messages, :turns, :drafts).find_by(id: params[:id])
        end
      end
    end
  end
end
