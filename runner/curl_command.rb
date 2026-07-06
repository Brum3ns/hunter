require "shellwords"
require "open3"
require "timeout"

# Validates and safely executes an attacker-influenced `curl` command.
#
# No shell is ever involved: the command is parsed into an argv array and run
# via Open3.capture3(*argv). Only `curl` against http/https is permitted, and a
# denylist blocks every flag that would let curl touch the filesystem. This file
# is duplicated at runner/curl_command.rb (as the same Sandbox::CurlCommand) so
# the runner container re-validates before executing — defense in depth.
module Sandbox
  module CurlCommand
    module_function

    # Real curl PoCs (e.g. Burp's "copy as curl") carry many -H headers and long
    # cookie/authorization values, so these ceilings are generous; they exist to
    # bound abuse, not to reject legitimate commands.
    MAX_ARGS = 400
    MAX_LENGTH = 32_000

    Result = Struct.new(
      :exit_status, :stdout, :stderr, :error, :duration_ms, :output_truncated,
      keyword_init: true
    )

    # Flags that write the filesystem or read local files.
    DENIED_FLAGS = %w[
      -o --output -O --remote-name --output-dir
      -T --upload-file -K --config -D --dump-header
      -c --cookie-jar --trace --trace-ascii
    ].freeze

    DATA_FLAGS = %w[-d --data --data-raw --data-binary --data-urlencode --data-ascii -F --form].freeze

    def validate(command)
      command = command.to_s
      return [false, "command is empty"] if command.strip.empty?
      return [false, "command is too long"] if command.length > MAX_LENGTH
      return [false, "command contains a newline (invalid)"] if command.match?(/[\r\n]/)
      return [false, "command contains a NUL byte (invalid)"] if command.include?("\u0000")

      begin
        argv = Shellwords.split(command)
      rescue ArgumentError
        return [false, "command could not be parsed"]
      end

      return [false, "command is empty"] if argv.empty?
      return [false, "command has too many arguments"] if argv.length > MAX_ARGS
      return [false, "command must invoke curl"] unless File.basename(argv[0]) == "curl"

      argv[1..].each_with_index do |arg, i|
        prev = argv[i] # argv[i] is the element before argv[1..][i]
        return [false, "flag #{arg} is not allowed"] if DENIED_FLAGS.include?(arg)
        if DATA_FLAGS.include?(prev) && arg.start_with?("@")
          return [false, "reading data from a file is not allowed"]
        end
        if arg.include?("://") && !arg.match?(%r{\Ahttps?://}i)
          return [false, "only http/https URLs are allowed"]
        end
      end

      urls = argv.select { |a| a.match?(%r{\Ahttps?://}i) }
      return [false, "no http/https URL found"] if urls.empty?

      [true, argv]
    end

    def execute(command, max_time:, max_output:)
      ok, argv_or_reason = validate(command)
      return Result.new(error: argv_or_reason, output_truncated: false) unless ok

      argv = with_safety_flags(argv_or_reason, max_time:, max_output:)
      started = monotonic_ms

      begin
        stdout, stderr, status = Timeout.timeout(max_time + 5) { capture(argv, binmode: true) }
      rescue Timeout::Error
        return Result.new(error: "timed out after #{max_time}s", duration_ms: monotonic_ms - started, output_truncated: false)
      rescue StandardError => e
        return Result.new(error: "execution failed: #{e.class}", duration_ms: monotonic_ms - started, output_truncated: false)
      end

      out, out_trunc = clip(stdout, max_output)
      err, err_trunc = clip(stderr, max_output)
      exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : status

      Result.new(
        exit_status: exit_status,
        stdout: out,
        stderr: err,
        error: nil,
        duration_ms: monotonic_ms - started,
        output_truncated: out_trunc || err_trunc
      )
    end

    # Seam for stubbing in tests. Returns [stdout, stderr, exit_status_int].
    def capture(argv, binmode: false)
      stdout, stderr, status = Open3.capture3(*argv, binmode: binmode)
      [stdout, stderr, status]
    end

    def with_safety_flags(argv, max_time:, max_output:)
      argv = argv.dup
      argv << "-sS" unless argv.include?("-sS") || argv.include?("--silent")
      argv.push("--max-time", max_time.to_s) unless argv.include?("--max-time")
      argv.push("--connect-timeout", "10") unless argv.include?("--connect-timeout")
      argv.push("--max-filesize", max_output.to_s) unless argv.include?("--max-filesize")
      argv
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
