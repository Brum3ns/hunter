module ControlCenter
  module Ansible
    module VariableResolver
      Result = Data.define(:values, :secret_values, :audit_values, :secret_names, :errors) do
        def valid? = errors.empty?
      end

      Entry = Data.define(:name, :value, :secret)
      VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      module_function

      def call(inventory:, playbooks:, launch_sets:, overrides:)
        resolved = {}
        errors = []

        levels = [
          [ "inventory", variables_from_sets(attached_sets(inventory)) ],
          [ "playbook", variables_from_sets(Array(playbooks).flat_map { |playbook| attached_sets(playbook) }) ],
          [ "launch", variables_from_sets(Array(launch_sets)) ],
          [ "override", Array(overrides) ]
        ]

        levels.each do |level, sources|
          entries, level_errors = build_level(level, sources)
          errors.concat(level_errors)
          entries.each { |entry| resolved[entry.name] = entry } if level_errors.empty?
        end

        values = resolved.transform_values(&:value)
        audit_values = resolved.filter_map do |name, entry|
          [ name, entry.value ] unless entry.secret
        end.to_h
        secret_entries = resolved.values.select(&:secret)

        Result.new(
          values: values,
          secret_values: secret_entries.flat_map { |entry| strings_in(entry.value) }.reject(&:empty?).uniq,
          audit_values: audit_values,
          secret_names: secret_entries.map(&:name),
          errors: errors
        )
      end

      def attached_sets(resource)
        return [] unless resource

        resource.variable_sets.to_a
      end
      private_class_method :attached_sets

      def variables_from_sets(variable_sets)
        variable_sets.flat_map { |variable_set| variable_set.variables.to_a }
      end
      private_class_method :variables_from_sets

      def build_level(level, sources)
        entries = []
        errors = []
        seen = {}
        duplicates = {}

        sources.each do |source|
          entry = level == "override" ? override_entry(source, errors) : variable_entry(source, errors)
          next unless entry

          if seen.key?(entry.name)
            unless duplicates[entry.name]
              errors << %(duplicate variable "#{entry.name}" at #{level} level)
              duplicates[entry.name] = true
            end
          else
            seen[entry.name] = true
            entries << entry
          end
        end

        [ entries, errors ]
      end
      private_class_method :build_level

      def variable_entry(variable, errors)
        if reserved_connection_name?(variable.name)
          errors << %(variable "#{variable.name}" is reserved for connection credentials)
          return
        end

        Entry.new(name: variable.name.to_s, value: variable.typed_value, secret: variable.secret == true)
      rescue TypedValue::Error => e
        errors << %(variable "#{variable.name}" #{e.message})
        nil
      end
      private_class_method :variable_entry

      def override_entry(override, errors)
        attributes = override.respond_to?(:to_h) ? override.to_h : {}
        name = attributes[:name] || attributes["name"]
        type = attributes[:value_type] || attributes["value_type"]
        value = attributes.key?(:value) ? attributes[:value] : attributes["value"]
        secret = attributes.key?(:secret) ? attributes[:secret] : attributes["secret"]

        unless name.to_s.match?(VARIABLE_NAME)
          errors << %(override "#{name}" has an invalid variable name)
          return
        end
        if reserved_connection_name?(name)
          errors << %(override "#{name}" is reserved for connection credentials)
          return
        end
        unless secret == true || secret == false
          errors << %(override "#{name}" secret must be a boolean)
          return
        end

        normalized = TypedValue.load(TypedValue.dump(value, type: type), type: type)
        Entry.new(name: name.to_s, value: normalized, secret: secret)
      rescue TypedValue::Error => e
        errors << %(override "#{name}" #{e.message})
        nil
      end
      private_class_method :override_entry

      def reserved_connection_name?(name)
        YamlLimits::VARIABLE_RESERVED_CONNECTION_KEYS.include?(name.to_s.downcase)
      end
      private_class_method :reserved_connection_name?

      def strings_in(value)
        case value
        when String then [ value ]
        when Integer, Float, TrueClass, FalseClass then [ value.to_s ]
        when Array then value.flat_map { |child| strings_in(child) }
        when Hash then value.values.flat_map { |child| strings_in(child) }
        else []
        end
      end
      private_class_method :strings_in
    end
  end
end
