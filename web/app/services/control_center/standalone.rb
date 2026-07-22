require "tmpdir"
require "fileutils"

module ControlCenter
  # Orchestrates one standalone job send: render the template into an ephemeral
  # cmdscript folder, write targets to a temp file, invoke the binary, and clean
  # up (Dir.mktmpdir removes the tree on block exit). Connection secrets come
  # from the inherited env, so no host/user/pass/token appears in argv.
  module Standalone
    module_function

    TIMEOUT = Integer(ENV.fetch("CONTROL_CENTER_JOB_TIMEOUT", "60"))
    MAX_OUTPUT = 262_144

    def submit(template:, targets:, queue_name:, target_chunk: 0, delay: 0)
      Dir.mktmpdir("hunter-cc-") do |dir|
        cmd_dir = File.join(dir, "cmdscript")
        FileUtils.mkdir_p(cmd_dir, mode: 0o700)
        File.write(File.join(cmd_dir, "#{template.name}.yaml"), TemplateRenderer.to_yaml(template))

        target_file = File.join(dir, "targets.txt")
        File.write(target_file, Array(targets).join("\n"))

        # Whiterabbit only chunks when -target-chunk > 0, and its chunk path aborts
        # unless -folder-nfs points at an existing directory. Provide one inside the
        # ephemeral tree so chunked sends work; targets travel inside the message for
        # target-block templates, so a per-job dir is sufficient here.
        nfs_dir = File.join(dir, "nfs")
        FileUtils.mkdir_p(nfs_dir, mode: 0o700)

        flags = [
          "-run", template.name,
          "-folder-cmdscript", cmd_dir,
          "-target", target_file,
          "-queue-name", queue_name.to_s,
          "-target-chunk", target_chunk.to_i.to_s,
          "-delay", delay.to_i.to_s,
          "-folder-nfs", nfs_dir,
          "-db", File.join(dir, "badgerdb")
        ]
        WhiterabbitCommand.execute(flags, timeout: TIMEOUT, max_output: MAX_OUTPUT)
      end
    end

    def health
      { rabbitmq: check("-check-rabbitmq"), mongo: check("-check-mongo") }
    end

    def check(flag)
      result = WhiterabbitCommand.execute([flag], timeout: 10, max_output: 8_192)
      ok = result.error.nil? && result.exit_status&.zero?
      detail = (result.error || result.stderr.presence || result.stdout).to_s.dup.force_encoding("UTF-8").scrub.strip
      { ok: ok, detail: detail }
    end
  end
end
