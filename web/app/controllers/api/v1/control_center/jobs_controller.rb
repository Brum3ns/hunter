module Api
  module V1
    module ControlCenter
      # Job history + submission. Submit re-validates the template (closing the
      # save-then-run TOCTOU window), records a pending Job, invokes the binary
      # via Standalone, and finalizes the Job with the captured result.
      class JobsController < BaseController
        def index
          jobs = ::ControlCenter::Job.order(created_at: :desc).limit(clamped_limit)
          render json: { jobs: jobs.map { |j| serialize(j) } }
        end

        def show
          job = ::ControlCenter::Job.find_by(id: params[:id])
          return render_not_found unless job
          render json: serialize(job)
        end

        def create
          template = ::ControlCenter::Template.find_by(name: params[:template])
          return render_not_found unless template

          errors = ::ControlCenter::TemplateValidator.call(template.commands)
          return render json: { error: "unprocessable_entity", detail: errors }, status: :unprocessable_entity if errors.any?

          targets = Array(params[:targets])
          queue = params[:queue_name].presence || "test"
          job = ::ControlCenter::Job.create!(
            template_name: template.name,
            template_snapshot: ::ControlCenter::TemplateRenderer.to_hash(template),
            queue_name: queue, target_count: targets.size, status: "pending",
            created_by: Current.user&.username
          )

          result = ::ControlCenter::Standalone.submit(
            template: template, targets: targets, queue_name: queue,
            target_chunk: params[:target_chunk].to_i, delay: params[:delay].to_i
          )
          finalize(job, result)
          render json: serialize(job), status: :created
        end

        private

        def finalize(job, result)
          succeeded = result.error.nil? && result.exit_status&.zero?
          job.update!(
            status: succeeded ? "succeeded" : "failed",
            exit_status: result.exit_status,
            stdout: text(result.stdout),
            stderr: text(result.error || result.stderr)
          )
        end

        def text(str)
          str.to_s.dup.force_encoding("UTF-8").scrub
        end

        def serialize(j)
          {
            id: j.id, template_name: j.template_name, queue_name: j.queue_name,
            target_count: j.target_count, status: j.status, exit_status: j.exit_status,
            stdout: j.stdout, stderr: j.stderr, created_by: j.created_by, created_at: j.created_at
          }
        end
      end
    end
  end
end
