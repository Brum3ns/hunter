require "digest"

module Assistant
  module DraftReview
    Review = Data.define(
      :destination,
      :destination_record,
      :destination_stale,
      :diff,
      :diff_digest
    )

    DESTINATION_CLASSES = {
      "whiterabbit_template" => ControlCenter::Template,
      "ansible_playbook" => ControlCenter::Ansible::Playbook
    }.freeze

    module_function

    def call(draft)
      destination = destination_metadata(draft)
      record = destination_record(draft)
      stale = destination.present? && (
        record.nil? || record.lock_version.to_s != draft.destination_lock_version.to_s
      )
      diff = build_diff(draft, record)
      Review.new(
        destination: destination,
        destination_record: record,
        destination_stale: stale,
        diff: diff,
        diff_digest: diff && Digest::SHA256.hexdigest(diff)
      )
    end

    def destination_metadata(draft)
      return if draft.destination_type.blank? && draft.destination_id.blank?

      {
        type: draft.destination_type,
        id: draft.destination_id.to_s,
        lock_version: draft.destination_lock_version.to_s
      }
    end
    private_class_method :destination_metadata

    def destination_record(draft)
      return if draft.destination_type.blank?

      DESTINATION_CLASSES[draft.destination_type]&.find_by(id: draft.destination_id)
    end
    private_class_method :destination_record

    def build_diff(draft, record)
      return unless record

      current = artifact_content(draft.artifact_type, record)
      proposed = proposed_content(draft)
      return unless current && proposed

      "--- current\n+++ proposed\n-#{current}\n+#{proposed}"
    end
    private_class_method :build_diff

    def artifact_content(artifact_type, record)
      if artifact_type == "ansible_playbook"
        record.yaml_content
      else
        ControlCenter::TemplateRenderer.to_yaml(record)
      end
    end
    private_class_method :artifact_content

    def proposed_content(draft)
      return draft.content if draft.artifact_type == "ansible_playbook"

      parsed = Assistant::DraftEnvelope.whiterabbit(JSON.parse(draft.content))
      return draft.content unless parsed.valid?

      ControlCenter::TemplateRenderer.to_yaml(ControlCenter::Template.new(parsed.normalized))
    rescue JSON::ParserError, TypeError
      draft.content
    end
    private_class_method :proposed_content
  end
end
