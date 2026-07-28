module Api
  module V1
    module ControlCenter
      module Ansible
        class RunsController < Api::V1::BaseController
          api_scope :control_center

          def show
            run = find_run
            return render_not_found unless run

            render json: serialize(run)
          end

          def cancel
            run = find_run
            return render_not_found unless run

            run = ::ControlCenter::Ansible::RunCancellation.cancel_run!(run)
            render json: serialize(run)
          rescue ::ControlCenter::Ansible::RunCancellation::Conflict => e
            render json: { error: "conflict", detail: e.message }, status: :conflict
          end

          private

          def find_run
            ::ControlCenter::Ansible::Run.find_by(id: params[:id])
          end

          def serialize(run)
            {
              id: run.id,
              run_group_id: run.run_group_id,
              playbook_id: run.playbook_id,
              position: run.position,
              status: run.status,
              playbook_name: run.playbook_name,
              inventory_name: run.inventory_name,
              credential_name: run.credential_name,
              credential_fingerprint: run.credential_fingerprint,
              variable_audit: run.variable_audit,
              secret_variable_names: run.secret_variable_names,
              host_limit: run.host_limit,
              check_mode: run.check_mode,
              timeout_seconds: run.timeout_seconds,
              error_code: run.error_code,
              error_detail: run.error_detail,
              exit_status: run.exit_status,
              ok_count: run.ok_count,
              changed_count: run.changed_count,
              failed_count: run.failed_count,
              unreachable_count: run.unreachable_count,
              stored_event_bytes: run.stored_event_bytes,
              truncated: run.truncated,
              queued_at: run.queued_at,
              started_at: run.started_at,
              completed_at: run.completed_at,
              cancel_requested_at: run.cancel_requested_at,
              created_at: run.created_at,
              updated_at: run.updated_at
            }
          end
        end
      end
    end
  end
end
