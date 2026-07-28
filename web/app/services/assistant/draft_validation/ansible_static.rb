module Assistant
  module DraftValidation
    module AnsibleStatic
      VALIDATION_VERSION = "ansible-static-v1"
      MAX_SOURCE_BYTES = 65_536
      PROHIBITED_MODULE_SUFFIXES = %w[
        shell command raw script include include_tasks import_tasks include_role import_role include_vars
      ].freeze
      DEPENDENCY_KEYS = %w[
        vars_files module_defaults library module_utils roles_path collections_path collections_paths fact_path
      ].freeze
      TASK_KEYWORDS = %w[
        name when tags register changed_when failed_when ignore_errors become become_user vars
        loop loop_control notify delegate_to run_once until retries delay block rescue always
        environment with_items any_errors_fatal check_mode diff no_log throttle poll async args
      ].freeze
      MESSAGE_BY_CODE = {
        "assistant_ansible_policy_unconfigured" => "Assistant Ansible module policy is not configured.",
        "ansible_source_invalid" => "Ansible source is invalid.",
        "ansible_source_too_large" => "Ansible source exceeds the assistant size limit.",
        "ansible_schema_invalid" => "Ansible source does not satisfy the playbook schema.",
        "ansible_module_not_allowed" => "Ansible source uses a module that is not permitted.",
        "ansible_roles_not_allowed" => "Ansible roles are not permitted.",
        "ansible_collections_not_allowed" => "Ansible collections are not permitted.",
        "ansible_include_not_allowed" => "Ansible includes and imports are not permitted.",
        "ansible_lookup_not_allowed" => "Ansible lookups are not permitted.",
        "ansible_environment_not_allowed" => "Task environment injection is not permitted.",
        "ansible_vars_prompt_not_allowed" => "Interactive Ansible variables are not permitted.",
        "ansible_absolute_path_not_allowed" => "Absolute paths are not permitted.",
        "ansible_url_not_allowed" => "URLs are not permitted in module or dependency locations.",
        "ansible_dependency_not_allowed" => "External Ansible dependency paths are not permitted.",
        "ansible_path_traversal_not_allowed" => "Relative path traversal is not permitted.",
        "ansible_secret_material_not_allowed" => "Secret-bearing Ansible content is not permitted."
      }.freeze

      module_function

      def call(yaml)
        source = yaml.is_a?(String) ? yaml : nil
        return result(false, [ "ansible_source_invalid" ]) unless source&.valid_encoding? && source.present?
        return result(false, [ "ansible_source_too_large" ]) if source.bytesize > MAX_SOURCE_BYTES

        allowlist = module_allowlist
        return result(false, [ "assistant_ansible_policy_unconfigured" ]) if allowlist.empty?

        generic = ControlCenter::Ansible::PlaybookValidator.call(source)
        return result(false, [ "ansible_schema_invalid" ]) unless generic.valid?

        codes = policy_codes(generic.document, allowlist)
        secret = Assistant::Context::SecretDetector.detect(source)
        codes << "ansible_secret_material_not_allowed" if secret
        codes.uniq!
        result(codes.empty?, codes, codes.empty? ? source : nil)
      end

      def module_allowlist
        ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"].to_s.split(",")
          .map(&:strip).reject(&:blank?).uniq
      end

      def policy_codes(document, allowlist)
        codes = []
        inspect_value(document, codes)
        Array(document).each do |play|
          next unless play.is_a?(Hash)

          ControlCenter::Ansible::PlaybookValidator::TASK_SECTIONS.each do |section|
            inspect_tasks(play[section], allowlist, codes)
          end
        end
        codes
      end
      private_class_method :policy_codes

      def inspect_tasks(tasks, allowlist, codes)
        Array(tasks).each do |task|
          next unless task.is_a?(Hash)

          module_keys = task.keys.map(&:to_s) - TASK_KEYWORDS
          module_keys.each do |name|
            suffix = name.downcase.split(".").last
            codes << "ansible_module_not_allowed" if
              PROHIBITED_MODULE_SUFFIXES.include?(suffix) || !allowlist.include?(name)
          end
          %w[block rescue always].each { |section| inspect_tasks(task[section], allowlist, codes) }
        end
      end
      private_class_method :inspect_tasks

      def inspect_value(value, codes)
        case value
        when Array
          value.each { |child| inspect_value(child, codes) }
        when Hash
          value.each do |raw_key, child|
            key = raw_key.to_s.downcase
            case key
            when "roles" then codes << "ansible_roles_not_allowed"
            when "collections" then codes << "ansible_collections_not_allowed"
            when "vars_prompt" then codes << "ansible_vars_prompt_not_allowed"
            when "environment" then codes << "ansible_environment_not_allowed"
            else
              codes << "ansible_include_not_allowed" if key.match?(/\A(?:include|import)/)
              codes << "ansible_lookup_not_allowed" if key.start_with?("with_")
              codes << "ansible_url_not_allowed" if key.include?("://")
              codes << "ansible_dependency_not_allowed" if DEPENDENCY_KEYS.include?(key) || key.end_with?("_plugins")
            end
            inspect_value(child, codes)
          end
        when String
          codes << "ansible_lookup_not_allowed" if value.match?(/\b(?:lookup|query)\s*\(/i)
          codes << "ansible_absolute_path_not_allowed" if value.match?(%r{\A/(?!/)})
          codes << "ansible_url_not_allowed" if value.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          codes << "ansible_path_traversal_not_allowed" if value.match?(%r{(?:\A|[\\/])\.\.(?:[\\/]|\z)})
        end
      end
      private_class_method :inspect_value

      def result(valid, codes, normalized = nil)
        Assistant::DraftValidation::Result.new(
          valid: valid,
          codes: codes.freeze,
          messages: codes.map { |code| MESSAGE_BY_CODE.fetch(code, "Ansible policy rejected the draft.") }.freeze,
          normalized: normalized,
          validation_version: VALIDATION_VERSION
        )
      end
      private_class_method :result
    end
  end
end
