require "digest"

module Assistant
  class ServiceIdentity < ApplicationRecord
    ROLES = %w[mcp_reader].freeze
    ROLE_MCP_READER = "mcp_reader"
    MCP_IDENTITY_NAME = "hunter-mcp"
    # Rejects a token too short to be worth trusting, matching the seed's
    # refusal to install a weak credential.
    MIN_TOKEN_LENGTH = 32

    self.table_name = "assistant_service_identities"

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true,
      uniqueness: { case_sensitive: false, conditions: -> { where(enabled: true) } },
      if: :enabled?
    validates :role, inclusion: { in: ROLES }
    validates :token_digest, presence: true, uniqueness: true,
      format: { with: /\A\h{64}\z/ }

    class << self
      def generate!(name:, role:)
        raw = SecureRandom.urlsafe_base64(32)
        record = create!(name: name, role: role, token_digest: digest(raw))
        [ record, raw ]
      end

      # Replaces the deleted bootstrap one-shot: the operator supplies the raw
      # token as ASSISTANT_MCP_HUNTER_TOKEN and db:seed installs its digest, so
      # no raw token ever transits a shared volume. Postgres still stores only
      # the SHA-256 digest.
      #
      # Idempotent, and deliberately safe to call with a token this database has
      # seen before: `token_digest` carries an UNQUALIFIED unique index, so a
      # previously-used token cannot simply be re-created once its row has been
      # disabled — that would raise RecordNotUnique and take db:seed, and
      # therefore boot, down with it. Reactivating the existing row instead makes
      # rolling back to an earlier token behave like rolling forward to a new one.
      def install_from_environment!(raw)
        raise ArgumentError, "assistant mcp token is too short" if raw.to_s.strip.length < MIN_TOKEN_LENGTH

        target_digest = digest(raw)

        transaction do
          existing = find_by(token_digest: target_digest)
          return existing if existing&.enabled? && existing.role == ROLE_MCP_READER

          # Retire every other active reader FIRST: the partial unique index on
          # lower(name) permits one enabled row per name, so the incumbent has to
          # step down before the winner can be installed.
          where(enabled: true, role: ROLE_MCP_READER)
            .where.not(token_digest: target_digest)
            .find_each { |superseded| superseded.update!(enabled: false, rotated_at: Time.current) }

          if existing
            existing.update!(
              name: MCP_IDENTITY_NAME, role: ROLE_MCP_READER, enabled: true, rotated_at: nil
            )
            existing
          else
            create!(name: MCP_IDENTITY_NAME, role: ROLE_MCP_READER, token_digest: target_digest)
          end
        end
      end

      def authenticate(raw, role:)
        return if raw.blank?

        presented_digest = digest(raw)
        identity = find_by(token_digest: presented_digest, enabled: true, role: role.to_s)
        return unless identity
        return unless ActiveSupport::SecurityUtils.secure_compare(identity.token_digest, presented_digest)

        identity.update_column(:last_used_at, Time.current)
        identity
      end

      def digest(raw)
        Digest::SHA256.hexdigest(raw.to_s)
      end
    end
  end
end
