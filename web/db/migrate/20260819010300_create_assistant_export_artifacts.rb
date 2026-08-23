class CreateAssistantExportArtifacts < ActiveRecord::Migration[8.0]
  def change
    create_table :assistant_export_artifacts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.binary :payload, null: false
      t.bigint :byte_count, null: false
      t.datetime :expires_at, null: false
      t.datetime :downloaded_at
      t.timestamps
    end

    add_index :assistant_export_artifacts, :expires_at
    add_check_constraint :assistant_export_artifacts, "byte_count >= 0",
      name: "assistant_export_artifacts_byte_count_nonnegative"
  end
end
