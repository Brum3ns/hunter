class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :favorites, dependent: :destroy
  has_many :trashes, dependent: :destroy
  has_many :program_views, dependent: :destroy
  has_many :scope_runs, dependent: :nullify
  has_many :program_changes, dependent: :destroy
  has_one :scope_schedule, dependent: :destroy
  has_one :monitor_config, dependent: :destroy

  normalizes :username, with: ->(u) { u.strip.downcase }

  def favorite_sids
    @favorite_sids ||= favorites.pluck(:program_sid).to_set
  end

  def trash_sids
    @trash_sids ||= trashes.pluck(:program_sid).to_set
  end

  # Recent program views, newest first. Skips views whose Mongo program has
  # since disappeared. Returns [[Program, viewed_at], ...].
  def recent_views(limit: 10)
    rows = program_views.order(viewed_at: :desc).limit(limit).pluck(:program_sid, :viewed_at)
    rows.filter_map do |sid, ts|
      prog = Programs::Source.find(sid)
      prog && [prog, ts]
    end
  end
end
