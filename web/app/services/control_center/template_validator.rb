module ControlCenter
  # Structural validation for command templates. Shared by the Template model
  # (validate-on-save) and the /validate endpoints (dry run). Returns
  # human-readable error strings; empty means valid.
  #
  # Executable names are deliberately unrestricted. Whiterabbit passes name and
  # args to Go's exec.Command without an implicit shell; selecting a shell or
  # interpreter explicitly gives that program its ordinary semantics.
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
        errors << "commands[#{i}].command contains a forbidden character (NUL or newline)" if name.match?(FORBIDDEN_CHARS)
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
