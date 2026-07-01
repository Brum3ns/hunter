require "securerandom"
require "digest"

# A runner is a machine identity (not a user) that pulls and executes jobs whose
# kind is in its `kinds` allowlist. Tokens are stored SHA-256 digest-only, minted
# out-of-band via `bin/rails runners:create`.
class Runner < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true

  def self.generate(name:, kinds:)
    raw = SecureRandom.urlsafe_base64(32)
    record = create!(name: name, kinds: Array(kinds).map(&:to_s), token_digest: digest(raw))
    [record, raw]
  end

  def self.authenticate(raw)
    raw = raw.to_s
    return nil if raw.empty?

    runner = find_by(token_digest: digest(raw))
    runner&.update_column(:last_seen_at, Time.current)
    runner
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end
end
