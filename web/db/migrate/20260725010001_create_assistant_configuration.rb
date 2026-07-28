class CreateAssistantConfiguration < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_provider_profiles do |t|
      t.string :name, null: false
      t.string :catalog_slug, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :secret_ref, null: false
      t.boolean :enabled, null: false, default: false
      t.integer :input_limit, null: false
      t.integer :output_limit, null: false
      t.integer :tool_call_limit, null: false, default: 8
      t.string :retention_posture, null: false
      t.datetime :reviewed_at
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :assistant_provider_profiles, "lower(name)", unique: true,
      name: "idx_assistant_profiles_lower_name"
    add_index :assistant_provider_profiles, :catalog_slug, unique: true
    add_check_constraint :assistant_provider_profiles, "input_limit > 0",
      name: "assistant_profiles_input_limit_positive"
    add_check_constraint :assistant_provider_profiles, "output_limit > 0",
      name: "assistant_profiles_output_limit_positive"
    add_check_constraint :assistant_provider_profiles, "tool_call_limit BETWEEN 1 AND 8",
      name: "assistant_profiles_tool_call_limit_bounded"

    create_table :assistant_settings do |t|
      t.boolean :singleton_key, null: false, default: true
      t.boolean :assistant_enabled, null: false, default: false
      t.integer :transcript_retention_days, null: false, default: 7
      t.integer :audit_retention_days, null: false, default: 90
      t.datetime :disabled_at
      t.references :disabled_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :assistant_settings, :singleton_key, unique: true
    add_check_constraint :assistant_settings, "singleton_key = TRUE",
      name: "assistant_settings_singleton_key_true"
    add_check_constraint :assistant_settings, "transcript_retention_days BETWEEN 1 AND 30",
      name: "assistant_settings_transcript_retention_bounded"
    add_check_constraint :assistant_settings, "audit_retention_days BETWEEN 1 AND 365",
      name: "assistant_settings_audit_retention_bounded"
  end
end
