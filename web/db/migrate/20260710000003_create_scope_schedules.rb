class CreateScopeSchedules < ActiveRecord::Migration[8.1]
  def change
    create_table :scope_schedules do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, null: false, default: false
      t.integer :interval_minutes, null: false, default: 60
      t.string  :mode, null: false, default: "all"
      t.boolean :bug_bounty, null: false, default: false
      t.boolean :vdp, null: false, default: false
      t.jsonb   :platforms, null: false, default: []
      t.datetime :last_run_at
      t.datetime :next_run_at
      t.timestamps
    end
  end
end
