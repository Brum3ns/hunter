module Assistant
  class ExportArtifact < ApplicationRecord
    self.table_name = "assistant_export_artifacts"

    TTL = 15.minutes
    MAX_BYTES = 12.megabytes

    belongs_to :user

    validates :kind, inclusion: { in: %w[ansible_playbooks] }
    validates :filename, :content_type, :payload, presence: true
    validates :byte_count, numericality: { only_integer: true, in: 1..MAX_BYTES }
    validates :expires_at, presence: true

    def browser_reference
      ttl = [ expires_at - Time.current, 1.second ].max
      "/assistant/exports/#{signed_id(expires_in: ttl, purpose: :assistant_export)}"
    end

    def safe_metadata
      {
        "kind" => kind, "filename" => filename, "byte_count" => byte_count,
        "expires_at" => expires_at.iso8601, "browser_download_reference" => browser_reference
      }
    end
  end
end
