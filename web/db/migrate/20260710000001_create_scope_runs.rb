class CreateScopeRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :scope_runs do |t|
      # Nullable: scheduled/system runs are not tied to a signed-in user.
      t.references :user, foreign_key: true, null: true
      t.string  :kind, null: false
      t.string  :platform
      t.string  :trigger, null: false, default: "manual"
      t.string  :mode
      t.boolean :bug_bounty, null: false, default: false
      t.boolean :vdp, null: false, default: false
      t.jsonb   :programs, null: false, default: []
      t.boolean :success
      t.integer :exit_status
      t.integer :duration_ms
      t.integer :stdout_bytes
      t.text    :stdout_excerpt
      t.text    :stderr_excerpt
      t.string  :error_class
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :scope_runs, :started_at
    add_index :scope_runs, [:kind, :platform]
  end
end
