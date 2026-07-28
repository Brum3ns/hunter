module Api
  module V1
    module ControlCenter
      # Job history, target-selection preview, and asynchronous submission.
      # create re-validates the template, persists a queued Job (freezing the
      # rendered template + the selection descriptor), and hands off to
      # ControlCenter::SubmitJob. resolve_targets previews the resolved count.
      class JobsController < BaseController
        api_scope :control_center

        def index
          jobs = ::ControlCenter::Job.order(created_at: :desc).limit(clamped_limit)
          render json: { jobs: jobs.map { |j| serialize(j) } }
        end

        def show
          job = ::ControlCenter::Job.find_by(id: params[:id])
          return render_not_found unless job
          render json: serialize(job)
        end

        def resolve_targets
          selections = selection_params
          ::ControlCenter::TargetSelection.validate!(selections)
          manual = manual_targets
          render json: {
            count: ::ControlCenter::TargetSelection.count(selections, manual),
            truncated: false,
            sample: ::ControlCenter::TargetSelection.sample(selections, manual, limit: 50)
          }
        rescue ::ControlCenter::TargetSelection::InvalidSelection => e
          render json: { error: "bad_request", detail: e.message }, status: :bad_request
        end

        def create
          template = ::ControlCenter::Template.find_by(name: params[:template])
          return render_not_found unless template

          errors = ::ControlCenter::TemplateValidator.call(template.commands)
          return render json: { error: "unprocessable_entity", detail: errors }, status: :unprocessable_entity if errors.any?

          selections = selection_params
          ::ControlCenter::TargetSelection.validate!(selections)

          key = params[:idempotency_key].presence
          if key && (existing = ::ControlCenter::Job.find_by(idempotency_key: key, created_by: Current.user&.username))
            return render json: serialize(existing), status: :created
          end

          job = ::ControlCenter::Job.create!(
            template_name: template.name,
            template_snapshot: ::ControlCenter::TemplateRenderer.to_hash(template),
            queue_name: params[:queue_name].presence || "test",
            selections: selections, manual_targets: manual_targets,
            target_chunk: params[:target_chunk].to_i, job_delay_ms: params[:delay].to_i,
            target_count: 0, status: "queued", idempotency_key: key,
            created_by: Current.user&.username
          )
          ::ControlCenter::SubmitJob.perform_later(job.id)
          render json: serialize(job), status: :created
        rescue ::ControlCenter::TargetSelection::InvalidSelection => e
          render json: { error: "bad_request", detail: e.message }, status: :bad_request
        end

        private

        def selection_params
          params.permit(selections: [:source, :mode, :q, { ids: [], exclude_ids: [] }])[:selections] || []
        end

        def manual_targets
          Array(params[:targets]).map { |t| t.to_s.strip }.reject(&:empty?)
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
