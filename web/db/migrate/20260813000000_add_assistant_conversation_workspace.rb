class AddAssistantConversationWorkspace < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_conversations, :history_position, :bigint
    add_index :assistant_conversations, %i[user_id history_position],
      name: "idx_assistant_conversations_user_history"

    add_column :assistant_settings, :conversation_management_enabled,
      :boolean, null: false, default: true
  end
end
