require "digest"

module Assistant
  module ConfirmedSave
    Result = Data.define(:record, :errors) do
      def success?
        errors.empty?
      end
    end

    module_function

    def call(draft:, user:, destination:)
      confirmation_snapshot = snapshot(draft)
      return failure("not_owner") unless draft.conversation.user_id == user&.id
      return failure("validation_incomplete") unless draft.validation_status == "valid"
      return failure("validation_stale") unless current_validation_version(draft) == draft.validation_version
      return failure("destination_mismatch") unless destination_matches?(draft, destination)

      validation = validate_current(draft)
      return failure(*validation.fetch(:errors)) if validation.fetch(:errors).any?

      persistence = nil
      locked_error = nil
      ActiveRecord::Base.transaction do
        draft.lock!
        locked_error = locked_precondition_error(
          draft, user, destination, confirmation_snapshot
        )
        raise ActiveRecord::Rollback if locked_error

        persistence = persist(
          draft: draft,
          destination: destination,
          user: user,
          attributes: validation.fetch(:attributes),
          expected_lock_version: confirmation_snapshot.fetch(:destination_lock_version)
        )
        unless persistence.success?
          raise ActiveRecord::Rollback
        end

        bind_destination!(draft, persistence.record)
        record_audit!(draft: draft, user: user, record: persistence.record)
      end

      return failure(locked_error) if locked_error
      return persistence_failure(persistence) unless persistence&.success?

      Result.new(record: persistence.record, errors: [])
    rescue ActiveRecord::ActiveRecordError
      failure("persistence_failed")
    end

    def current_validation_version(draft)
      case draft.artifact_type
      when "whiterabbit_template"
        Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION
      when "ansible_playbook"
        Assistant::ValidationDispatcher::VALIDATION_VERSION
      end
    end
    private_class_method :current_validation_version

    def locked_precondition_error(draft, user, destination, confirmation_snapshot)
      return "confirmation_stale" unless snapshot(draft) == confirmation_snapshot
      return "not_owner" unless draft.conversation.user_id == user&.id
      return "validation_incomplete" unless draft.validation_status == "valid"
      return "validation_stale" unless current_validation_version(draft) == draft.validation_version
      return "destination_mismatch" unless destination_matches?(draft, destination)
    end
    private_class_method :locked_precondition_error

    def snapshot(draft)
      {
        name: draft.name,
        content_digest: draft.content_digest,
        validation_status: draft.validation_status,
        validation_version: draft.validation_version,
        destination_type: draft.destination_type,
        destination_id: draft.destination_id,
        destination_lock_version: draft.destination_lock_version
      }
    end
    private_class_method :snapshot

    def validate_current(draft)
      case draft.artifact_type
      when "whiterabbit_template" then validate_whiterabbit(draft)
      when "ansible_playbook" then validate_ansible(draft)
      else { attributes: nil, errors: [ "artifact_type_invalid" ] }
      end
    end
    private_class_method :validate_current

    def validate_whiterabbit(draft)
      attributes = JSON.parse(draft.content)
      result = Assistant::DraftValidation::Whiterabbit.call(attributes)
      errors = result.valid? ? [] : [ "validation_failed", *result.codes ]
      errors << "draft_name_mismatch" if result.valid? && result.normalized.fetch("name") != draft.name
      { attributes: result.normalized, errors: errors }
    rescue JSON::ParserError, TypeError
      { attributes: nil, errors: [ "validation_failed", "whiterabbit_draft_invalid" ] }
    end
    private_class_method :validate_whiterabbit

    def validate_ansible(draft)
      envelope = Assistant::DraftEnvelope.ansible("name" => draft.name, "source" => draft.content)
      unless envelope.valid?
        return { attributes: nil, errors: [ "validation_failed", *envelope.codes ] }
      end

      result = Assistant::DraftValidation::AnsibleStatic.call(envelope.normalized.fetch("source"))
      errors = result.valid? ? [] : [ "validation_failed", *result.codes ]
      if result.valid? && !ansible_validation_evidence?(draft)
        errors = [ "validation_failed", "ansible_validation_evidence_missing" ]
      end
      {
        attributes: { name: envelope.normalized.fetch("name"), yaml_content: result.normalized },
        errors: errors
      }
    end
    private_class_method :validate_ansible

    def ansible_validation_evidence?(draft)
      Assistant::ValidationRequest.where(
        turn_id: draft.turn_id,
        status: "valid",
        source_digest: draft.content_digest
      ).any? do |request|
        stored = request.result.to_h.stringify_keys
        stored["validation_version"] == Assistant::ValidationDispatcher::VALIDATION_VERSION &&
          stored["normalized"] == draft.content
      end
    end
    private_class_method :ansible_validation_evidence?

    def destination_matches?(draft, destination)
      if draft.destination_type.blank? || draft.destination_id.blank?
        return destination.nil? && draft.destination_type.blank? && draft.destination_id.blank?
      end
      return false unless destination

      destination_type(destination) == draft.destination_type &&
        destination.id.to_s == draft.destination_id.to_s
    end
    private_class_method :destination_matches?

    def destination_type(destination)
      case destination
      when ControlCenter::Template then "whiterabbit_template"
      when ControlCenter::Ansible::Playbook then "ansible_playbook"
      end
    end
    private_class_method :destination_type

    def persist(draft:, destination:, user:, attributes:, expected_lock_version:)
      case draft.artifact_type
      when "whiterabbit_template"
        ControlCenter::Templates::Persist.call(
          record: destination || ControlCenter::Template.new,
          attributes: attributes,
          user: user,
          expected_lock_version: expected_lock_version
        )
      when "ansible_playbook"
        ControlCenter::Ansible::Playbooks::Persist.call(
          record: destination || ControlCenter::Ansible::Playbook.new,
          attributes: attributes,
          user: user,
          expected_lock_version: expected_lock_version
        )
      end
    end
    private_class_method :persist

    def bind_destination!(draft, record)
      draft.update!(
        destination_type: draft.artifact_type,
        destination_id: record.id.to_s,
        destination_lock_version: record.lock_version.to_s
      )
    end
    private_class_method :bind_destination!

    def record_audit!(draft:, user:, record:)
      Assistant::Audit.record!(event: "draft.confirmed_save", attributes: {
        correlation_id: draft.turn.correlation_id,
        user_id: user.id,
        conversation_id: draft.conversation_id,
        turn_id: draft.turn_id,
        provider_profile_id: draft.turn.provider_profile_id,
        status: "saved",
        resource_type: draft.artifact_type,
        resource_id: draft.validation_version,
        content_hash: resulting_content_hash(draft.artifact_type, record),
        target_type: draft.artifact_type,
        target_id: record.id.to_s,
        metadata: {
          operation: "confirmed_save",
          outcome: "saved",
          source: draft.content_digest
        }
      })
    end
    private_class_method :record_audit!

    def resulting_content_hash(artifact_type, record)
      return record.checksum if artifact_type == "ansible_playbook"

      Digest::SHA256.hexdigest(ControlCenter::TemplateRenderer.to_yaml(record))
    end
    private_class_method :resulting_content_hash

    def persistence_failure(persistence)
      return failure("persistence_failed") unless persistence
      return failure("destination_stale") if persistence.errors[:base].include?("destination_stale")

      codes = persistence.errors.attribute_names.map { |attribute| "persistence_#{attribute}_invalid" }
      failure(*(codes.presence || [ "persistence_failed" ]))
    end
    private_class_method :persistence_failure

    def failure(*errors)
      Result.new(record: nil, errors: errors.flatten.compact.uniq.freeze)
    end
    private_class_method :failure
  end
end
