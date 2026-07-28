module Assistant
  class RateLimitBucket < ApplicationRecord
    self.table_name = "assistant_rate_limit_buckets"

    belongs_to :user

    validates :action, presence: true, length: { maximum: 100 },
      format: { with: /\A[a-z0-9_.-]+\z/ }
    validates :window_started_at, presence: true,
      uniqueness: { scope: %i[user_id action] }
    validates :count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
