class CreateRunnerJobs < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :runner_jobs, id: :uuid do |t|
      t.string   :kind, null: false
      t.text     :command, null: false
      t.string   :vulnerability_id, null: false
      t.string   :status, null: false, default: "queued"
      t.integer  :exit_status
      t.text     :stdout
      t.text     :stderr
      t.boolean  :output_truncated, null: false, default: false
      t.string   :error
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :runner, foreign_key: true
      t.integer  :duration_ms
      t.datetime :claimed_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :runner_jobs, %i[status kind created_at]
  end
end
