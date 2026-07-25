module ControlCenter
  module Ansible
    module SingleLaunch
      class Error < StandardError
        attr_reader :details

        def initialize(details)
          @details = details
          super("Ansible launch is invalid")
        end
      end

      HOST_LIMIT_PATTERN = /\A[A-Za-z0-9_.:,*?!&\-\[\]]+\z/
      MIN_TIMEOUT_SECONDS = 60
      MAX_TIMEOUT_SECONDS = 86_400
      DEFAULT_CLAIM_TIMEOUT_SECONDS = 300

      module_function

      def call(user:, playbook_id:, inventory_id:, credential_id: nil, variable_set_ids: [], overrides: [],
        host_limit: nil, check_mode: false, timeout_seconds: 3600)
        errors = Hash.new { |hash, key| hash[key] = [] }
        playbook = find_resource(Playbook, playbook_id, :playbook_id, errors)
        inventory = find_resource(Inventory, inventory_id, :inventory_id, errors)
        credential = resolve_credential(inventory, credential_id, errors)
        launch_sets = resolve_variable_sets(variable_set_ids, errors)
        normalized_limit = normalize_host_limit(host_limit, errors)
        normalized_timeout = normalize_timeout(timeout_seconds, errors)
        validate_check_mode(check_mode, errors)
        validate_saved_resources(playbook, inventory, errors)
        validate_inventory_approval(inventory, errors)
        validate_credential(credential, errors)

        resolution = resolve_variables(
          inventory:, playbook:, launch_sets:, overrides:, errors:
        )
        raise Error, errors.to_h if errors.any?

        persist_launch(
          user:, playbook:, inventory:, credential:, launch_sets:, overrides:,
          resolution:, host_limit: normalized_limit, check_mode:,
          timeout_seconds: normalized_timeout
        )
      end

      def find_resource(model, id, key, errors)
        record = model.find_by(id: id)
        errors[key] << "was not found" unless record
        record
      end
      private_class_method :find_resource

      def resolve_credential(inventory, requested_id, errors)
        return unless inventory

        if requested_id.present?
          credential = Credential.find_by(id: requested_id)
          errors[:credential_id] << "was not found" unless credential
          credential
        else
          credential = inventory.default_credential
          errors[:credential_id] << "must select a credential" unless credential
          credential
        end
      end
      private_class_method :resolve_credential

      def resolve_variable_sets(raw_ids, errors)
        ids = normalize_ids(raw_ids)
        unless ids
          errors[:variable_set_ids] << "must contain integer IDs"
          return []
        end
        if ids.uniq.length != ids.length
          errors[:variable_set_ids] << "must contain unique IDs"
          return []
        end

        by_id = VariableSet.where(id: ids).index_by(&:id)
        if by_id.length != ids.length
          errors[:variable_set_ids] << "contains an unknown variable set"
          return []
        end
        ids.map { |id| by_id.fetch(id) }
      end
      private_class_method :resolve_variable_sets

      def normalize_ids(raw_ids)
        Array(raw_ids).map do |id|
          id.is_a?(Integer) ? id : Integer(id.to_s, 10)
        end
      rescue ArgumentError, TypeError
        nil
      end
      private_class_method :normalize_ids

      def normalize_host_limit(raw_limit, errors)
        return nil if raw_limit.nil? || (raw_limit.is_a?(String) && raw_limit.strip.empty?)
        unless raw_limit.is_a?(String)
          errors[:host_limit] << "must be a string"
          return
        end

        limit = raw_limit.strip
        if limit.bytesize > 255
          errors[:host_limit] << "must be at most 255 bytes"
        elsif !limit.match?(HOST_LIMIT_PATTERN)
          errors[:host_limit] << "contains unsupported characters"
        end
        limit
      end
      private_class_method :normalize_host_limit

      def normalize_timeout(raw_timeout, errors)
        timeout = raw_timeout.is_a?(Integer) ? raw_timeout : Integer(raw_timeout.to_s, 10)
        unless timeout.between?(MIN_TIMEOUT_SECONDS, MAX_TIMEOUT_SECONDS)
          errors[:timeout_seconds] << "must be between 60 and 86400"
        end
        timeout
      rescue ArgumentError, TypeError
        errors[:timeout_seconds] << "must be an integer"
        nil
      end
      private_class_method :normalize_timeout

      def validate_check_mode(check_mode, errors)
        return if check_mode == true || check_mode == false

        errors[:check_mode] << "must be a boolean"
      end
      private_class_method :validate_check_mode

      def validate_saved_resources(playbook, inventory, errors)
        if playbook
          result = PlaybookValidator.call(playbook.yaml_content)
          errors[:playbook_id].concat(result.errors) unless result.valid?
        end
        if inventory
          result = InventoryValidator.call(inventory.yaml_content)
          errors[:inventory_id].concat(result.errors) unless result.valid?
        end
      end
      private_class_method :validate_saved_resources

      def validate_inventory_approval(inventory, errors)
        return unless inventory
        return if inventory.known_hosts.present? && inventory.host_key_fingerprints.present?

        errors[:inventory_id] << "must have approved host keys"
      end
      private_class_method :validate_inventory_approval

      def validate_credential(credential, errors)
        return unless credential

        usable = case credential.auth_type
        when "private_key" then credential.private_key.present?
        when "password" then credential.ssh_password.present?
        else false
        end
        return if usable

        description = credential.auth_type == "private_key" ? "private key" : "password"
        errors[:credential_id] << "does not have a usable #{description}"
      end
      private_class_method :validate_credential

      def resolve_variables(inventory:, playbook:, launch_sets:, overrides:, errors:)
        return unless inventory && playbook

        resolution = VariableResolver.call(
          inventory:, playbooks: [ playbook ], launch_sets:, overrides: Array(overrides)
        )
        errors[:variables].concat(resolution.errors) unless resolution.valid?
        resolution
      end
      private_class_method :resolve_variables

      def persist_launch(user:, playbook:, inventory:, credential:, launch_sets:, overrides:, resolution:,
        host_limit:, check_mode:, timeout_seconds:)
        now = Time.current
        payload = RunPayload.call(
          playbook:, inventory:, credential:, resolution:, host_limit:, check_mode:, timeout_seconds:
        )

        RunGroup.transaction do
          group = RunGroup.create!(
            status: "queued",
            inventory:,
            credential:,
            created_by: user,
            execution_payload: payload,
            launch_snapshot: launch_snapshot(
              playbook:, inventory:, credential:, launch_sets:, overrides:,
              host_limit:, check_mode:, timeout_seconds:
            )
          )
          Run.create!(
            run_group: group,
            playbook:,
            position: 0,
            status: "queued",
            playbook_yaml: playbook.yaml_content,
            inventory_yaml: inventory.yaml_content,
            known_hosts: inventory.known_hosts,
            variable_audit: resolution.audit_values,
            secret_variable_names: resolution.secret_names,
            playbook_name: playbook.name,
            inventory_name: inventory.name,
            credential_name: credential.name,
            credential_fingerprint: credential.public_key_fingerprint,
            host_limit:,
            check_mode:,
            timeout_seconds:,
            queued_at: now,
            claim_deadline: now + claim_timeout_seconds
          )
          group.reload
        end
      end
      private_class_method :persist_launch

      def launch_snapshot(playbook:, inventory:, credential:, launch_sets:, overrides:, host_limit:,
        check_mode:, timeout_seconds:)
        normalized_overrides = Array(overrides).map { |override| override.respond_to?(:to_h) ? override.to_h : {} }
        {
          "playbook" => { "id" => playbook.id, "name" => playbook.name, "checksum" => playbook.checksum },
          "inventory" => { "id" => inventory.id, "name" => inventory.name, "checksum" => inventory.checksum },
          "credential" => {
            "id" => credential.id,
            "name" => credential.name,
            "fingerprint" => credential.public_key_fingerprint
          },
          "variable_set_ids" => launch_sets.map(&:id),
          "overrides" => normalized_overrides.reject { |override| override_value(override, :secret) == true }
            .map { |override| non_secret_override(override) },
          "secret_override_names" => normalized_overrides.filter_map do |override|
            override_value(override, :name).to_s if override_value(override, :secret) == true
          end,
          "options" => {
            "host_limit" => host_limit,
            "check_mode" => check_mode,
            "timeout_seconds" => timeout_seconds
          }
        }
      end
      private_class_method :launch_snapshot

      def non_secret_override(override)
        {
          "name" => override_value(override, :name).to_s,
          "value_type" => override_value(override, :value_type).to_s,
          "value" => override_value(override, :value)
        }
      end
      private_class_method :non_secret_override

      def override_value(override, key)
        override.key?(key) ? override[key] : override[key.to_s]
      end
      private_class_method :override_value

      def claim_timeout_seconds
        Integer(ENV.fetch("ANSIBLE_CLAIM_TIMEOUT_SECONDS", DEFAULT_CLAIM_TIMEOUT_SECONDS.to_s), 10)
      end
      private_class_method :claim_timeout_seconds
    end
  end
end
