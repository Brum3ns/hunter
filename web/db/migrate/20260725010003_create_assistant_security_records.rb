class CreateAssistantSecurityRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_service_identities do |t|
      t.string :name, null: false
      t.string :role, null: false
      t.string :token_digest, null: false
      t.boolean :enabled, null: false, default: true
      t.datetime :last_used_at
      t.datetime :rotated_at
      t.timestamps
    end
    add_index :assistant_service_identities, :token_digest, unique: true
    add_index :assistant_service_identities, "lower(name)", unique: true,
      where: "enabled", name: "idx_assistant_service_identities_active_name"

    create_table :assistant_turn_grants do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :conversation, null: false,
        foreign_key: { to_table: :assistant_conversations, on_delete: :cascade }
      t.references :turn, null: false,
        foreign_key: { to_table: :assistant_turns, on_delete: :cascade }
      t.references :provider_profile, null: false,
        foreign_key: { to_table: :assistant_provider_profiles }
      t.string :token_digest, null: false
      t.jsonb :resources, null: false, default: []
      t.string :tools, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.integer :max_calls, null: false
      t.integer :call_count, null: false, default: 0
      t.integer :max_result_bytes, null: false
      t.integer :max_total_bytes, null: false
      t.integer :returned_bytes, null: false, default: 0
      t.integer :reserved_bytes, null: false, default: 0
      t.datetime :revoked_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :assistant_turn_grants, :token_digest, unique: true
    add_index :assistant_turn_grants, %i[turn_id expires_at],
      name: "idx_assistant_turn_grants_turn_expiry"
    add_check_constraint :assistant_turn_grants,
      "max_calls > 0 AND call_count >= 0 AND call_count <= max_calls",
      name: "assistant_turn_grants_call_counts_bounded"
    add_check_constraint :assistant_turn_grants,
      "max_result_bytes > 0 AND max_total_bytes >= max_result_bytes",
      name: "assistant_turn_grants_byte_limits_positive"
    add_check_constraint :assistant_turn_grants,
      "returned_bytes >= 0 AND reserved_bytes >= 0 AND returned_bytes + reserved_bytes <= max_total_bytes",
      name: "assistant_turn_grants_byte_usage_bounded"

    create_table :assistant_audit_events do |t|
      t.uuid :correlation_id
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :conversation,
        foreign_key: { to_table: :assistant_conversations, on_delete: :nullify }
      t.references :turn, foreign_key: { to_table: :assistant_turns, on_delete: :nullify }
      t.references :provider_profile,
        foreign_key: { to_table: :assistant_provider_profiles, on_delete: :nullify }
      t.string :event, null: false
      t.string :status
      t.string :model
      t.string :tool
      t.string :resource_type
      t.string :resource_id
      t.integer :byte_count
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :latency_ms
      t.string :validation_codes, array: true, null: false, default: []
      t.string :content_hash
      t.string :target_type
      t.string :target_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :assistant_audit_events, %i[event created_at],
      name: "idx_assistant_audit_events_event_created"
    add_index :assistant_audit_events, :expires_at
    add_index :assistant_audit_events, :correlation_id
    add_check_constraint :assistant_audit_events,
      "byte_count IS NULL OR byte_count >= 0",
      name: "assistant_audit_events_byte_count_nonnegative"
    add_check_constraint :assistant_audit_events,
      "input_tokens IS NULL OR input_tokens >= 0",
      name: "assistant_audit_events_input_tokens_nonnegative"
    add_check_constraint :assistant_audit_events,
      "output_tokens IS NULL OR output_tokens >= 0",
      name: "assistant_audit_events_output_tokens_nonnegative"
    add_check_constraint :assistant_audit_events,
      "latency_ms IS NULL OR latency_ms >= 0",
      name: "assistant_audit_events_latency_nonnegative"
  end
end
