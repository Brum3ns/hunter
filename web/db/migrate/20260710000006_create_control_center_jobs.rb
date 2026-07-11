class CreateControlCenterJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_jobs do |t|
      t.string   :template_name, null: false
      t.jsonb    :template_snapshot, null: false, default: {}
      t.string   :queue_name, null: false, default: "test"
      t.integer  :target_count, null: false, default: 0
      t.string   :status, null: false, default: "pending"
      t.integer  :exit_status
      t.text     :stdout
      t.text     :stderr
      t.string   :created_by
      t.timestamps
    end
    add_index :control_center_jobs, :created_at
  end
end
