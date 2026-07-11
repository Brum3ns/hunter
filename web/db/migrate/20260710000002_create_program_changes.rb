class CreateProgramChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :program_changes do |t|
      t.references :user, null: false, foreign_key: true
      # The fetch run that surfaced this change, when there was one.
      t.references :scope_run, null: true, foreign_key: true
      t.string  :platform
      t.string  :program_sid
      t.string  :program_name
      t.string  :kind, null: false
      t.jsonb   :old_value
      t.jsonb   :new_value
      t.datetime :detected_at, null: false
      t.timestamps
    end

    add_index :program_changes, [:user_id, :detected_at]
    add_index :program_changes, [:user_id, :platform]
  end
end
