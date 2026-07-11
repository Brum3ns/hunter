class CreateMonitorConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :monitor_configs do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, null: false, default: false
      t.integer :interval_seconds, null: false, default: 300
      t.jsonb   :platforms, null: false, default: []
      t.datetime :last_tick_at
      t.datetime :next_tick_at
      t.timestamps
    end
  end
end
