class CreateAssistantValidationRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_validation_requests, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :turn, null: false,
        foreign_key: { to_table: :assistant_turns, on_delete: :cascade }
      t.references :turn_grant, null: false,
        foreign_key: { to_table: :assistant_turn_grants, on_delete: :cascade }
      t.references :draft,
        foreign_key: { to_table: :assistant_drafts, on_delete: :nullify }
      t.string :status, null: false, default: "pending"
      t.text :source
      t.string :source_digest, null: false
      t.text :result
      t.uuid :terminal_event_id
      t.datetime :expires_at, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :assistant_validation_requests, %i[turn_id status],
      name: "idx_assistant_validation_requests_turn_status"
    add_index :assistant_validation_requests, %i[turn_grant_id expires_at],
      name: "idx_assistant_validation_requests_grant_expiry"
    add_index :assistant_validation_requests, :terminal_event_id,
      unique: true, where: "terminal_event_id IS NOT NULL"
    add_check_constraint :assistant_validation_requests,
      "status IN ('pending', 'valid', 'invalid', 'failed', 'expired')",
      name: "assistant_validation_requests_status"
  end
end
