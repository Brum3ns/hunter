module Vulnerabilities
  class RunsController < Vulnerabilities::BaseController
    def create
      doc = Vulnerabilities::MongoSource.find(params[:id])
      return head :not_found unless doc

      command = doc.dig("poc", "curl").to_s
      return head :unprocessable_entity if command.strip.empty?

      ok, reason = Sandbox::CurlCommand.validate(command)
      @job = RunnerJob.create!(
        kind: "curl",
        command: command,
        vulnerability_id: params[:id],
        requested_by: Current.user,
        status: ok ? "queued" : "failed",
        error: ok ? nil : reason,
        finished_at: ok ? nil : Time.current
      )

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to vulnerabilities_detail_path(params[:id]) }
      end
    end

    def show
      @job = RunnerJob.find_by(id: params[:job_id], vulnerability_id: params[:id], requested_by: Current.user)
      return head :not_found unless @job

      @job.reap_if_stale!
      render layout: false
    end
  end
end
