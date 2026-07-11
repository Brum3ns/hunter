module ControlCenter
  # Structural + allowlist validation for command templates. Shared by the
  # Template model (validate-on-save) and the /validate endpoint (dry run).
  # Returns human-readable error strings; empty means valid.
  module TemplateValidator
    module_function

    ALLOWED_OPERATORS = ["", "|", "&&", "||"].freeze
    MAX_COMMANDS = 50
    MAX_ARGS = 200
    MAX_ARG_LENGTH = 4_096
    # Conservative default recon toolage; override via env (comma-separated).
    DEFAULT_ALLOWLIST = %w[httpx nuclei ffuf subfinder katana naabu dnsx gau waymore gowitness].freeze
    # Shell metacharacters rejected in args (operators live in their own field).
    METACHARACTERS = /[;&|`$<>\r\n ]/

    def allowlist
      raw = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
      return DEFAULT_ALLOWLIST if raw.nil?
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    def call(commands)
      errors = []
      commands = Array(commands)
      errors << "at least one command is required" if commands.empty?
      errors << "too many commands (max #{MAX_COMMANDS})" if commands.size > MAX_COMMANDS

      commands.each_with_index do |raw, i|
        cmd = (raw || {}).to_h.transform_keys(&:to_s)
        name = cmd["command"].to_s
        args = Array(cmd["args"])
        operator = cmd["operator"].to_s

        errors << "commands[#{i}].command is required" if name.empty?
        errors << "commands[#{i}].command #{name.inspect} is not allowed" if !name.empty? && !allowlist.include?(name)
        errors << "commands[#{i}].operator #{operator.inspect} is invalid" unless ALLOWED_OPERATORS.include?(operator)
        errors << "commands[#{i}] has too many args (max #{MAX_ARGS})" if args.size > MAX_ARGS

        args.each_with_index do |arg, j|
          s = arg.to_s
          errors << "commands[#{i}].args[#{j}] is too long (max #{MAX_ARG_LENGTH})" if s.length > MAX_ARG_LENGTH
          errors << "commands[#{i}].args[#{j}] contains a disallowed metacharacter" if s.match?(METACHARACTERS)
        end
      end
      errors
    end
  end
end
