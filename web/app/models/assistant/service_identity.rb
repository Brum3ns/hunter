require "digest"

module Assistant
  class ServiceIdentity < ApplicationRecord
    ROLES = %w[mcp_reader].freeze

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
