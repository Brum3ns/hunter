class CreateAssistantConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_conversations do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :provider_profile, null: false,
        foreign_key: { to_table: :assistant_provider_profiles }
      t.string :status, null: false, default: "active"
      t.string :title, null: false, default: "New conversation"
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :assistant_conversations, %i[user_id updated_at],
      name: "idx_assistant_conversations_user_updated"
    add_index :assistant_conversations, %i[status expires_at],
      name: "idx_assistant_conversations_status_expiry"

    create_table :assistant_turns do |t|
      t.references :conversation, null: false,
        foreign_key: { to_table: :assistant_conversations, on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :provider_profile, null: false,
        foreign_key: { to_table: :assistant_provider_profiles }
      t.uuid :correlation_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :status, null: false, default: "created"
      t.string :error_code
      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :tool_call_count, null: false, default: 0
      t.timestamps
    end
    add_index :assistant_turns, :correlation_id, unique: true
    add_index :assistant_turns, %i[user_id status created_at],
      name: "idx_assistant_turns_user_status_created"
    add_index :assistant_turns, %i[conversation_id status],
      name: "idx_assistant_turns_conversation_status"
    add_check_constraint :assistant_turns,
      "input_tokens >= 0 AND output_tokens >= 0 AND tool_call_count >= 0",
      name: "assistant_turns_nonnegative_counters"

    create_table :assistant_messages do |t|
      t.references :conversation, null: false,
        foreign_key: { to_table: :assistant_conversations, on_delete: :cascade }
      t.references :turn,
        foreign_key: { to_table: :assistant_turns, on_delete: :nullify }
      t.string :role, null: false
      t.text :body, null: false
      t.integer :sequence, null: false
      t.timestamps
    end
    add_index :assistant_messages, %i[conversation_id sequence], unique: true,
      name: "idx_assistant_messages_conversation_sequence"
    add_check_constraint :assistant_messages, "sequence >= 0",
      name: "assistant_messages_sequence_nonnegative"

    create_table :assistant_context_references do |t|
      t.references :turn, null: false,
        foreign_key: { to_table: :assistant_turns, on_delete: :cascade }
      t.string :resource_type, null: false
      t.string :resource_id, null: false
      t.string :label, null: false
      t.string :serializer_version, null: false, default: "v1"
      t.timestamps
    end
    add_index :assistant_context_references, %i[turn_id resource_type resource_id],
      unique: true, name: "idx_assistant_context_turn_resource"

    create_table :assistant_drafts do |t|
      t.references :conversation, null: false,
        foreign_key: { to_table: :assistant_conversations, on_delete: :cascade }
      t.references :turn, null: false,
        foreign_key: { to_table: :assistant_turns, on_delete: :cascade }
      t.string :artifact_type, null: false
      t.string :name, null: false
      t.text :content, null: false
      t.text :validation_details, null: false
      t.string :validation_status, null: false, default: "pending"
      t.string :validation_version, null: false
      t.string :content_digest, null: false
      t.string :destination_type
      t.string :destination_id
      t.string :destination_lock_version
      t.timestamps
    end
    add_index :assistant_drafts, %i[conversation_id created_at],
      name: "idx_assistant_drafts_conversation_created"
    add_index :assistant_drafts, %i[turn_id validation_status],
      name: "idx_assistant_drafts_turn_validation"
  end
end
