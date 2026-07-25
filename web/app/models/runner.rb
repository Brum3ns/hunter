require "securerandom"
require "digest"

# A runner is a machine identity (not a user) that pulls and executes jobs whose
# kind is in its `kinds` allowlist. Tokens are stored SHA-256 digest-only, minted
# out-of-band via `bin/rails runners:create`.
class Runner < ApplicationRecord
  # Raised when a preset RUNNER_TOKEN is present but too weak to trust. We fail
  # closed rather than register a brute-forceable machine identity.
  class WeakTokenError < StandardError; end

  # A preset token must clear this floor. `openssl rand -base64 32` (44 chars) and
  # `SecureRandom.urlsafe_base64(32)` (43 chars) both satisfy it comfortably.
  MINIMUM_TOKEN_LENGTH = 32
  KINDS = %w[curl ansible].freeze

  has_many :runner_jobs, dependent: :nullify

  before_validation :normalize_kinds

  validates :name, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true
  validates :kinds, presence: true
  validate :kinds_are_supported

  def self.generate(name:, kinds:)
    raw = SecureRandom.urlsafe_base64(32)
    record = create!(name: name, kinds: Array(kinds).map(&:to_s), token_digest: digest(raw))
    [record, raw]
  end

  # Register (or update) a single runner from a token chosen out of band — the
  # RUNNER_TOKEN shared with the runner container — so operators can set one
  # static secret instead of minting, copying, and restarting. Idempotent on
  # `name`: rotating the token updates the same row rather than orphaning
  # runners. Only the SHA-256 digest is persisted; the raw token never lands in
  # the database. Returns the runner, or nil when no token is configured.
  def self.ensure_from_token!(name:, token:, kinds:)
    token = normalize_token(token)
    return nil if token.empty?

    if token.length < MINIMUM_TOKEN_LENGTH
      raise WeakTokenError, "RUNNER_TOKEN must be at least #{MINIMUM_TOKEN_LENGTH} characters"
    end

    runner = find_or_initialize_by(name: name)
    runner.token_digest = digest(token)
    runner.kinds = Array(kinds).map(&:to_s)
    runner.save!
    runner
  end

  # Canonicalize an env-sourced token so the web (which digests it here) and the
  # runner agent (which sends it) agree byte-for-byte regardless of how the value
  # was quoted in .env or delivered by the container runtime: trim whitespace,
  # then a single layer of matching surrounding quotes, then whitespace again.
  # The runner agent applies the identical rule.
  def self.normalize_token(raw)
    value = raw.to_s.strip
    if value.length >= 2 &&
       ((value.start_with?('"') && value.end_with?('"')) ||
        (value.start_with?("'") && value.end_with?("'")))
      value = value[1..-2].strip
    end
    value
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

  private

  def normalize_kinds
    self.kinds = Array(kinds).map { |kind| kind.to_s.strip }.reject(&:blank?).uniq
  end

  def kinds_are_supported
    unknown = kinds - KINDS
    errors.add(:kinds, "contains unsupported values: #{unknown.join(', ')}") if unknown.any?
  end
end
