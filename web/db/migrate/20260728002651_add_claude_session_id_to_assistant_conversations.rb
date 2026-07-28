class AddClaudeSessionIdToAssistantConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_conversations, :claude_session_id, :string
  end
end
