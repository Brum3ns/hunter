module Api
  module V1
    module ControlCenter
      module Ansible
        class RunGroupsController < Api::V1::BaseController
          api_scope :control_center

          def index
            page = pagination_page
            limit = clamped_limit
            scope = ::ControlCenter::Ansible::RunGroup.includes(:runs).order(created_at: :desc, id: :desc)
            groups = scope.offset((page - 1) * limit).limit(limit)
            render json: {
              run_groups: groups.map { |group| serialize_group(group, children: false) },
              pagination: { page:, limit:, total: scope.count }
            }
          end

          def show
            group = find_group
            return render_not_found unless group

            render json: serialize_group(group, children: true)
          end

          def create
            group = ::ControlCenter::Ansible::SingleLaunch.call(user: Current.user, **launch_attributes)
            render json: serialize_group(group, children: true), status: :created
          rescue ::ControlCenter::Ansible::SingleLaunch::Error => e
            render json: { error: "unprocessable_entity", details: e.details }, status: :unprocessable_entity
          end

          def cancel
            group = find_group
            return render_not_found unless group

            group = ::ControlCenter::Ansible::RunCancellation.cancel_group!(group)
            render json: serialize_group(group, children: true)
          rescue ::ControlCenter::Ansible::RunCancellation::Conflict => e
            render json: { error: "conflict", detail: e.message }, status: :conflict
          end

          private

          def find_group
            ::ControlCenter::Ansible::RunGroup.includes(:runs).find_by(id: params[:id])
          end

          def launch_attributes
            permitted = params.permit(
              :playbook_id, :inventory_id, :credential_id, :host_limit, :check_mode, :timeout_seconds,
              variable_set_ids: []
            ).to_h.symbolize_keys
            permitted[:overrides] = Array(params[:overrides]).map do |raw_override|
              override = raw_override.respond_to?(:to_unsafe_h) ? raw_override.to_unsafe_h : raw_override.to_h
              override.slice("name", "value_type", "value", "secret")
            end
            permitted
          end

          def serialize_group(group, children:)
            body = {
              id: group.id,
              status: group.status,
              execution_mode: group.execution_mode,
              failure_policy: group.failure_policy,
              concurrency_limit: group.concurrency_limit,
              inventory_id: group.inventory_id,
              credential_id: group.credential_id,
              launch_snapshot: group.launch_snapshot,
              cancel_requested_at: group.cancel_requested_at,
              started_at: group.started_at,
              completed_at: group.completed_at,
              created_at: group.created_at,
              updated_at: group.updated_at
            }
            body[:runs] = group.runs.map { |run| serialize_run_summary(run) } if children
            body
          end

          def serialize_run_summary(run)
            {
              id: run.id,
              position: run.position,
              status: run.status,
              playbook_name: run.playbook_name,
              inventory_name: run.inventory_name,
              credential_name: run.credential_name,
              check_mode: run.check_mode,
              timeout_seconds: run.timeout_seconds,
              error_code: run.error_code,
              ok_count: run.ok_count,
              changed_count: run.changed_count,
              failed_count: run.failed_count,
              unreachable_count: run.unreachable_count,
              truncated: run.truncated,
              queued_at: run.queued_at,
              started_at: run.started_at,
              completed_at: run.completed_at,
              cancel_requested_at: run.cancel_requested_at
            }
          end
        end
      end
    end
  end
end
