class AddSelectionFieldsToControlCenterJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :control_center_jobs, :selections, :jsonb, null: false, default: []
    add_column :control_center_jobs, :manual_targets, :jsonb, null: false, default: []
    add_column :control_center_jobs, :target_chunk, :integer, null: false, default: 0
    add_column :control_center_jobs, :job_delay_ms, :integer, null: false, default: 0
    add_column :control_center_jobs, :idempotency_key, :string
    add_index :control_center_jobs, %i[created_by idempotency_key],
              unique: true, where: "idempotency_key IS NOT NULL",
              name: "idx_cc_jobs_idempotency"
  end
end
