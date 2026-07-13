require "digest"

# A long-lived API token for a user. Only the SHA-256 digest of the raw token is
# stored; the raw value is shown once at creation time (via the
# `api_tokens:create` rake task) and never again.
class ApiToken < ApplicationRecord
  belongs_to :user

  MODULE_SCOPES = %w[cves vulnerabilities programs targets control_center].freeze
  WILDCARD = "*".freeze

  # Looks up a token by raw value, touching last_used_at. Returns the ApiToken
  # (so callers can read scope + saved filter) or nil on miss.
  def self.authenticate(raw)
    return nil if raw.blank?
    token = find_by(token_digest: digest(raw))
    return nil unless token

    token.update_column(:last_used_at, Time.current)
    token
  end

  # Mints a new token, persisting only its digest. Returns [record, raw_token].
  def self.generate(user:, name:, scopes: [WILDCARD])
    raw = SecureRandom.urlsafe_base64(32)
    record = create!(user: user, name: name, token_digest: digest(raw), scopes: scopes)
    [record, raw]
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  def allows_scope?(slug)
    scopes.include?(WILDCARD) || scopes.include?(slug.to_s)
  end
end
