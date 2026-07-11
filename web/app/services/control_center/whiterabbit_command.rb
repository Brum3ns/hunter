require "open3"
require "timeout"

module ControlCenter
  # Validates and safely executes the `whiterabbit standalone` binary. No shell:
  # argv is passed straight to Open3.capture3. Only the standalone subcommand and
  # an allowlist of flags are permitted; secrets travel via the inherited env,
  # never argv. Modeled on Sandbox::CurlCommand.
  module WhiterabbitCommand
    module_function

    SUBCOMMAND = "standalone"
    MAX_TOKENS = 64
    MAX_TOKEN_LENGTH = 8_192

    ALLOWED_FLAGS = %w[
      -run -folder-cmdscript -folder-workflow -target -target-chunk
      -queue-name -delay -salt -db -timeout
      -list -validate -check-rabbitmq -check-mongo -info
    ].freeze

    Result = Struct.new(
      :exit_status, :stdout, :stderr, :error, :duration_ms, :output_truncated,
      keyword_init: true
    )

    def bin
      ENV.fetch("WHITERABBIT_BIN", "/usr/local/bin/whiterabbit")
    end

    def validate(flags)
      flags = Array(flags)
      return [false, "too many arguments"] if flags.size > MAX_TOKENS

      flags.each do |token|
        s = token.to_s
        return [false, "argument is too long"] if s.length > MAX_TOKEN_LENGTH
        # Reject NUL/CR/LF only. Spaces are safe: argv is passed straight to
        # Open3.capture3 with no shell involved, so a space can never re-split a
        # token into two arguments.
        return [false, "argument contains a NUL or newline"] if s.match?(/[\x00\r\n]/)
        return [false, "flag #{s} is not allowed"] if s.start_with?("-") && !ALLOWED_FLAGS.include?(s)
      end
      [true, flags.map(&:to_s)]
    end

    def execute(flags, timeout:, max_output:)
      ok, argv_or_reason = validate(flags)
      return Result.new(error: argv_or_reason, output_truncated: false) unless ok

      argv = [bin, SUBCOMMAND, *argv_or_reason]
      started = monotonic_ms

      # Timeout.timeout treats a sec of 0 (or nil) as "no timeout at all" (see
      # stdlib timeout.rb), which is the exact opposite of what a caller asking
      # for a 0s budget wants from a hardened wrapper. Treat any non-positive
      # timeout as already expired instead of handing it to Timeout.timeout.
      if timeout.to_f <= 0
        return Result.new(error: "timed out after #{timeout}s", duration_ms: monotonic_ms - started, output_truncated: false)
      end

      begin
        stdout, stderr, status = Timeout.timeout(timeout) { capture(argv) }
      rescue Timeout::Error
        return Result.new(error: "timed out after #{timeout}s", duration_ms: monotonic_ms - started, output_truncated: false)
      rescue StandardError => e
        return Result.new(error: "execution failed: #{e.class}", duration_ms: monotonic_ms - started, output_truncated: false)
      end

      out, out_trunc = clip(stdout, max_output)
      err, err_trunc = clip(stderr, max_output)
      exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : status

      Result.new(
        exit_status: exit_status, stdout: out, stderr: err, error: nil,
        duration_ms: monotonic_ms - started, output_truncated: out_trunc || err_trunc
      )
    end

    # Seam for stubbing in tests. Returns [stdout, stderr, exit_status_int].
    def capture(argv)
      Open3.capture3(*argv)
    end

    def clip(str, max_bytes)
      str = str.to_s.b
      return [str, false] if str.bytesize <= max_bytes
      [str.byteslice(0, max_bytes), true]
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end
  end
end
