class AddCodexThreadIdToAssistantConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_conversations, :codex_thread_id, :string
  end
end
