class CreateAssistantRateLimitBuckets < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_rate_limit_buckets do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :action, null: false
      t.datetime :window_started_at, null: false
      t.integer :count, null: false, default: 0
      t.timestamps
    end

    add_index :assistant_rate_limit_buckets,
      %i[user_id action window_started_at],
      unique: true,
      name: "idx_assistant_rate_buckets_unique_window"
    add_check_constraint :assistant_rate_limit_buckets,
      "count >= 0",
      name: "assistant_rate_limit_buckets_count_nonnegative"
  end
end
