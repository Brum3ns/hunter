module ControlCenter
  # Structural validation for command templates. Shared by the Template model
  # (validate-on-save) and the /validate endpoints (dry run). Returns
  # human-readable error strings; empty means valid.
  #
  # Security model: Whiterabbit executes every command via Go's
  # exec.Command(name, args...) — argv, with NO shell (operators pipe stdout->stdin
  # in Go). So shell metacharacters, spaces, and quotes in args are passed
  # literally and cannot inject commands; only NUL and CR/LF are forbidden because
  # they corrupt JSON/YAML serialization and the newline-delimited target file.
  # Placeholders (__TARGET_FILE__, __TARGET_STDIN__, __UUID__) are ordinary tokens
  # substituted by the worker at run time, so they validate freely. The command
  # allowlist is OPT-IN: empty/unset means any command may run.
  module TemplateValidator
    module_function

    ALLOWED_OPERATORS = ["", "|", "&&", "||"].freeze
    MAX_COMMANDS = 50
    MAX_ARGS = 200
    MAX_ARG_LENGTH = 4_096
    # NUL and CR/LF break serialization + the target-file line format; nothing
    # else is dangerous without a shell (spaces, quotes, and shell metacharacters
    # are all allowed because they are passed literally as argv).
    FORBIDDEN_CHARS = /[\x00\r\n]/

    # Optional command allowlist. nil (env empty/unset) means any command is
    # allowed. Set CONTROL_CENTER_COMMAND_ALLOWLIST to a comma-separated list to
    # restrict which binaries templates may invoke.
    def allowlist
      raw = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"].to_s.strip
      return nil if raw.empty?
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    def call(commands)
      errors = []
      commands = Array(commands)
      errors << "at least one command is required" if commands.empty?
      errors << "too many commands (max #{MAX_COMMANDS})" if commands.size > MAX_COMMANDS
      list = allowlist

      commands.each_with_index do |raw, i|
        cmd = (raw || {}).to_h.transform_keys(&:to_s)
        name = cmd["command"].to_s
        args = Array(cmd["args"])
        operator = cmd["operator"].to_s

        errors << "commands[#{i}].command is required" if name.empty?
        errors << "commands[#{i}].command contains a forbidden character (NUL or newline)" if name.match?(FORBIDDEN_CHARS)
        errors << "commands[#{i}].command #{name.inspect} is not allowed" if list && !name.empty? && !list.include?(name)
        errors << "commands[#{i}].operator #{operator.inspect} is invalid" unless ALLOWED_OPERATORS.include?(operator)
        errors << "commands[#{i}] has too many args (max #{MAX_ARGS})" if args.size > MAX_ARGS

        args.each_with_index do |arg, j|
          s = arg.to_s
          errors << "commands[#{i}].args[#{j}] is too long (max #{MAX_ARG_LENGTH})" if s.length > MAX_ARG_LENGTH
          errors << "commands[#{i}].args[#{j}] contains a forbidden character (NUL or newline)" if s.match?(FORBIDDEN_CHARS)
        end
      end
      errors
    end
  end
end
