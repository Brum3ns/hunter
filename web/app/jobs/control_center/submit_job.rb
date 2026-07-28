require "tmpdir"

module ControlCenter
  # Runs one job submission off the request cycle: stream the resolved target
  # list to a temp file, invoke Whiterabbit, and finalize the Job. Memory stays
  # flat regardless of target count because TargetSelection.stream yields.
  class SubmitJob < ApplicationJob
    queue_as :background

    DEFAULT_CHUNK = Integer(ENV.fetch("CONTROL_CENTER_DEFAULT_TARGET_CHUNK", "100"))
    MAX_STDERR = 262_144

    def perform(job_id)
      job = ControlCenter::Job.find_by(id: job_id)
      return unless job && job.status == "queued"

      job.update!(status: "running")
      template = ControlCenter::Template.find_by(name: job.template_name)
      return job.update!(status: "failed", stderr: "template no longer exists") unless template

      Dir.mktmpdir("hunter-cc-targets-") do |dir|
        target_file = File.join(dir, "targets.txt")
        count = 0
        File.open(target_file, "w") do |io|
          ControlCenter::TargetSelection.stream(job.selections, job.manual_targets) do |t|
            io.puts(t)
            count += 1
          end
        end
        job.update!(target_count: count)

        chunk = job.target_chunk.to_i
        chunk = DEFAULT_CHUNK if chunk <= 0

        result = ControlCenter::Standalone.submit(
          template: template, target_file: target_file,
          queue_name: job.queue_name, target_chunk: chunk, delay: job.job_delay_ms.to_i
        )
        finalize(job, result)
      end
    rescue => e
      job&.update(status: "failed", stderr: e.message.to_s.byteslice(0, MAX_STDERR))
      raise
    end

    private

    def finalize(job, result)
      succeeded = result.error.nil? && result.exit_status&.zero?
      job.update!(
        status: succeeded ? "succeeded" : "failed",
        exit_status: result.exit_status,
        stdout: scrub(result.stdout),
        stderr: scrub(result.error || result.stderr)
      )
    end

    def scrub(str)
      str.to_s.dup.force_encoding("UTF-8").scrub
    end
  end
end
