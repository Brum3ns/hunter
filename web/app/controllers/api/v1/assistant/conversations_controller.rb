module Api
  module V1
    module Assistant
      class ConversationsController < BaseController
        before_action :require_assistant_enabled!, only: %i[create update reorder]
        before_action :require_conversation_management_enabled!, only: %i[update reorder]

        def index
          conversations = current_assistant_user.assistant_conversations
            .includes(:provider_profile).history_ordered
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

        def update
          conversation = owned_conversation
          return render_not_found unless conversation

          attributes = exact_request_body!(%w[title])
          unless attributes["title"].is_a?(String)
            raise ActionController::ParameterMissing, "title"
          end

          renamed = conversation.rename_by!(
            actor: current_assistant_user,
            title: attributes.fetch("title")
          )
          render json: serialize_conversation(renamed)
        rescue ActiveRecord::RecordInvalid => error
          render_validation_errors(error.record)
        end

        def reorder
          attributes = exact_request_body!(%w[conversation_ids])
          unless attributes["conversation_ids"].is_a?(Array)
            raise ActionController::ParameterMissing, "conversation_ids"
          end

          conversations = ::Assistant::ConversationOrganization.reorder!(
            user: current_assistant_user,
            conversation_ids: attributes.fetch("conversation_ids")
          )
          render json: {
            conversations: conversations.map { |conversation| serialize_conversation(conversation) }
          }
        rescue ::Assistant::ConversationOrganization::InvalidOrder => error
          status = error.code == "conversation_order_stale" ? :conflict : :unprocessable_entity
          render json: { error: error.code }, status: status
        end

        def destroy
          conversation = owned_conversation
          return render_not_found unless conversation

          conversation.destroy_with_content!(actor: current_assistant_user)
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
