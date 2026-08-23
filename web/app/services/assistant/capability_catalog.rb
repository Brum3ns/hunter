require "yaml"

module Assistant
  class CapabilityCatalog
    class InvalidCatalog < StandardError; end

    DEFAULT_PATH = Rails.root.join("config/assistant_capabilities.yml")
    TOP_LEVEL_KEYS = %w[version tools api_classifications].freeze
    TOOL_KEYS = %w[
      name module operation effect scope input_schema_version
      output_schema_version machine_method machine_path api_operation gate
      rate_profile byte_profile idempotency locking secret_input secret_output
      audit_event target_metadata rollout
    ].freeze
    EFFECTS = %w[read analyze create update validate export execute cancel restore].freeze
    ROLLOUT_STATES = %w[planned enabled disabled].freeze
    SECRET_POLICIES = %w[deny].freeze
    CLASSIFICATIONS = %w[
      enabled excluded_secret excluded_delete excluded_governance
      excluded_machine_identity internal_mcp_backend api_alias
    ].freeze
    PROHIBITED_GENERIC_NAMES = %w[
      request http_request network_request shell run_command filesystem database
      credential send schedule execute
    ].freeze
    CLASSIFICATION_KEYS = %w[classification tool alias_of reason].freeze

    attr_reader :version, :tools, :api_classifications

    class << self
      def load(path: DEFAULT_PATH)
        document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        new(document)
      rescue Psych::Exception => error
        raise InvalidCatalog, "catalog YAML is invalid: #{error.message}"
      end
    end

    def initialize(document)
      validate_document!(document)
      @version = document.fetch("version")
      @tools = deep_freeze(document.fetch("tools").map(&:deep_dup))
      @api_classifications = deep_freeze(document.fetch("api_classifications").deep_dup)
      @tools_by_name = @tools.index_by { |tool| tool.fetch("name") }.freeze
      freeze
    end

    def tool!(name)
      @tools_by_name.fetch(name.to_s) do
        raise InvalidCatalog, "unknown capability tool: #{name}"
      end
    end

    def scopes
      tools.map { |tool| tool.fetch("scope") }.uniq.freeze
    end

    private

    def validate_document!(document)
      invalid!("catalog must be an object") unless document.is_a?(Hash)
      validate_exact_keys!(document, TOP_LEVEL_KEYS, "catalog")
      invalid!("version must be a positive integer") unless document["version"].is_a?(Integer) && document["version"].positive?
      invalid!("tools must be an array") unless document["tools"].is_a?(Array)
      invalid!("api_classifications must be an object") unless document["api_classifications"].is_a?(Hash)

      names = {}
      document.fetch("tools").each_with_index do |tool, index|
        validate_tool!(tool, index)
        name = tool.fetch("name")
        invalid!("duplicate tool name: #{name}") if names.key?(name)
        names[name] = true
      end
      validate_classifications!(document.fetch("api_classifications"), names)
    end

    def validate_tool!(tool, index)
      location = "tools[#{index}]"
      invalid!("#{location} must be an object") unless tool.is_a?(Hash)
      validate_exact_keys!(tool, TOOL_KEYS, location)

      TOOL_KEYS.each do |key|
        invalid!("#{location}.#{key} is required") if tool[key].nil?
      end
      invalid!("#{location}.name must be snake_case") unless tool["name"].match?(/\A[a-z][a-z0-9_]*\z/)
      invalid!("#{location}.name is a prohibited generic capability") if PROHIBITED_GENERIC_NAMES.include?(tool["name"])
      invalid!("#{location}.scope must be an exact non-wildcard scope") unless exact_scope?(tool["scope"])
      invalid!("#{location}.effect is invalid") unless EFFECTS.include?(tool["effect"])
      invalid!("#{location}.rollout is invalid") unless ROLLOUT_STATES.include?(tool["rollout"])
      invalid!("#{location} must deny secret input and output") unless
        SECRET_POLICIES.include?(tool["secret_input"]) && SECRET_POLICIES.include?(tool["secret_output"])
      invalid!("#{location}.machine_method must be an allowed non-delete method") unless
        %w[GET POST PATCH PUT].include?(tool["machine_method"])
      invalid!("#{location}.machine_path must be an Assistant machine route") unless
        tool["machine_path"].start_with?("/api/v1/assistant/machine/")
      invalid!("#{location}.target_metadata must be an array") unless tool["target_metadata"].is_a?(Array)
      %w[input_schema_version output_schema_version].each do |key|
        invalid!("#{location}.#{key} must be a positive integer") unless
          tool[key].is_a?(Integer) && tool[key].positive?
      end
    end

    def validate_classifications!(classifications, tool_names)
      classifications.each do |operation, entry|
        invalid!("invalid API operation key: #{operation}") unless
          operation.match?(/\A(?:GET|POST|PATCH|PUT|DELETE) \/api\/v1\/.+\z/)
        invalid!("classification for #{operation} must be an object") unless entry.is_a?(Hash)
        validate_allowed_keys!(entry, CLASSIFICATION_KEYS, "classification for #{operation}")
        classification = entry["classification"]
        invalid!("classification for #{operation} is invalid") unless CLASSIFICATIONS.include?(classification)

        if classification == "enabled"
          tool = entry["tool"]
          invalid!("enabled classification for #{operation} requires a known tool") unless tool_names.key?(tool)
        elsif entry.key?("tool")
          invalid!("#{classification} classification for #{operation} cannot name a tool")
        end

        if classification == "api_alias"
          invalid!("api_alias classification for #{operation} requires alias_of") if entry["alias_of"].blank?
        elsif entry.key?("alias_of")
          invalid!("#{classification} classification for #{operation} cannot name alias_of")
        end
      end
    end

    def validate_exact_keys!(value, allowed, location)
      missing = allowed - value.keys
      invalid!("#{location} is missing keys: #{missing.join(', ')}") if missing.any?
      validate_allowed_keys!(value, allowed, location)
    end

    def validate_allowed_keys!(value, allowed, location)
      unknown = value.keys - allowed
      invalid!("#{location} has unknown keys: #{unknown.join(', ')}") if unknown.any?
    end

    def exact_scope?(value)
      value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_]*\z/) && !value.include?("*")
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array
        value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def invalid!(message)
      raise InvalidCatalog, message
    end
  end
end
