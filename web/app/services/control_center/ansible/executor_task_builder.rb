module ControlCenter
  module Ansible
    module ExecutorTaskBuilder
      class Error < StandardError
        attr_reader :code

        def initialize(message, code: "invalid_task")
          @code = code
          super(message)
        end
      end

      DEFAULT_CLAIM_TIMEOUT_SECONDS = 300
      module_function

      def host_key_scan(user:, inventory:, now: Time.current)
        create_task(
          kind: "host_key_scan",
          user:,
          inventory:,
          payload: { "targets" => targets_for(inventory) },
          now:
        )
      end

      def syntax_check(user:, inventory:, playbook:, now: Time.current)
        validate_playbook!(playbook)
        create_task(
          kind: "syntax_check",
          user:,
          inventory:,
          playbook:,
          payload: {
            "playbook_yaml" => playbook.yaml_content,
            "inventory_yaml" => inventory.yaml_content,
            "targets" => targets_for(inventory),
            "options" => { "check_mode" => false, "host_limit" => nil }
          },
          now:
        )
      end

      def connectivity_test(user:, inventory:, credential: nil, now: Time.current)
        unless inventory.known_hosts.present? && inventory.host_key_fingerprints.present?
          raise Error.new("inventory must have approved host keys", code: "inventory_unapproved")
        end
        credential ||= inventory.default_credential
        validate_credential!(credential)

        create_task(
          kind: "connectivity_test",
          user:,
          inventory:,
          payload: {
            "targets" => targets_for(inventory),
            "known_hosts" => inventory.known_hosts,
            "credential" => {
              "username" => credential.username,
              "private_key" => credential.private_key,
              "ssh_password" => credential.ssh_password,
              "private_key_passphrase" => credential.private_key_passphrase,
              "become_password" => credential.become_password
            }
          },
          now:
        )
      end

      def targets_for(inventory)
        parsed = InventoryValidator.call(inventory.yaml_content)
        raise Error, parsed.errors.join(", ") unless parsed.valid?

        targets = []
        parsed.document.each_value { |group| collect_targets(group, targets) }
        raise Error, "inventory must contain at least one host" if targets.empty?

        targets.uniq { |target| [ target["host"], target["port"] ] }
      end

      def collect_targets(group, targets)
        return unless group.is_a?(Hash)

        group.fetch("hosts", {}).each do |host, attributes|
          attributes = {} unless attributes.is_a?(Hash)
          targets << {
            "host" => host.to_s,
            "address" => attributes.fetch("ansible_host", host).to_s,
            "port" => attributes.fetch("ansible_port", 22)
          }
        end
        group.fetch("children", {}).each_value { |child| collect_targets(child, targets) }
      end
      private_class_method :collect_targets

      def create_task(kind:, user:, inventory:, payload:, now:, playbook: nil)
        ExecutorTask.create!(
          kind:,
          created_by: user,
          inventory:,
          playbook:,
          execution_payload: payload,
          claim_deadline: now + claim_timeout_seconds
        )
      end
      private_class_method :create_task

      def validate_playbook!(playbook)
        result = PlaybookValidator.call(playbook.yaml_content)
        raise Error, result.errors.join(", ") unless result.valid?
      end
      private_class_method :validate_playbook!

      def validate_credential!(credential)
        unless credential
          raise Error.new("a credential is required", code: "credential_missing")
        end
        usable = credential.auth_type == "password" ? credential.ssh_password.present? : credential.private_key.present?
        return if usable

        raise Error.new("credential authentication material is missing", code: "credential_missing")
      end
      private_class_method :validate_credential!

      def claim_timeout_seconds
        Integer(ENV.fetch("ANSIBLE_CLAIM_TIMEOUT_SECONDS", DEFAULT_CLAIM_TIMEOUT_SECONDS.to_s), 10)
      end
      private_class_method :claim_timeout_seconds
    end
  end
end
