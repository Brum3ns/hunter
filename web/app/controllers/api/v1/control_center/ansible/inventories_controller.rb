module Api
  module V1
    module ControlCenter
      module Ansible
        class InventoriesController < Api::V1::BaseController
          api_scope :control_center

          def index
            inventories = ::ControlCenter::Ansible::Inventory
              .includes(:variable_sets).order(Arel.sql("LOWER(name) ASC"), :id)
            render json: { inventories: inventories.map { |inventory| serialize(inventory) } }
          end

          def show
            inventory = find_inventory
            return render_not_found unless inventory

            render json: serialize(inventory)
          end

          def create
            inventory = ::ControlCenter::Ansible::Inventory.new(created_by: Current.user)
            persist(inventory, status: :created)
          end

          def update
            inventory = find_inventory
            return render_not_found unless inventory

            persist(inventory)
          end

          def destroy
            inventory = find_inventory
            return render_not_found unless inventory

            inventory.destroy!
            head :no_content
          end

          def validate
            result = ::ControlCenter::Ansible::InventoryValidator.call(params[:yaml_content])
            render json: { valid: result.valid?, errors: result.errors }
          end

          def syntax_check
            inventory = find_inventory
            return render_not_found unless inventory
            playbook = ::ControlCenter::Ansible::Playbook.find_by(id: params[:playbook_id])
            return render_not_found unless playbook

            task = ::ControlCenter::Ansible::ExecutorTaskBuilder.syntax_check(
              user: Current.user, inventory:, playbook:
            )
            render json: serialize_task(task), status: :accepted
          rescue ::ControlCenter::Ansible::ExecutorTaskBuilder::Error => e
            render_task_error(e)
          end

          def host_key_scan
            inventory = find_inventory
            return render_not_found unless inventory

            task = ::ControlCenter::Ansible::ExecutorTaskBuilder.host_key_scan(
              user: Current.user, inventory:
            )
            render json: serialize_task(task), status: :accepted
          rescue ::ControlCenter::Ansible::ExecutorTaskBuilder::Error => e
            render_task_error(e)
          end

          def connectivity_test
            inventory = find_inventory
            return render_not_found unless inventory
            credential = requested_credential
            return render_not_found if params[:credential_id].present? && !credential

            task = ::ControlCenter::Ansible::ExecutorTaskBuilder.connectivity_test(
              user: Current.user, inventory:, credential:
            )
            render json: serialize_task(task), status: :accepted
          rescue ::ControlCenter::Ansible::ExecutorTaskBuilder::Error => e
            render_task_error(e)
          end

          def confirm_host_keys
            inventory = find_inventory
            return render_not_found unless inventory

            candidates = Array(params[:candidates]).map do |candidate|
              candidate.respond_to?(:to_unsafe_h) ? candidate.to_unsafe_h : candidate.to_h
            end
            inventory = ::ControlCenter::Ansible::HostKeyConfirmation.call(
              inventory:, candidates:
            )
            render json: serialize(inventory)
          rescue ::ControlCenter::Ansible::HostKeyConfirmation::Error => e
            render_task_error(e)
          end

          def executor_task
            inventory = find_inventory
            return render_not_found unless inventory
            task = ::ControlCenter::Ansible::ExecutorTask.find_by(
              id: params[:task_id], inventory_id: inventory.id
            )
            return render_not_found unless task

            render json: serialize_task(task)
          end

          private

          def find_inventory
            ::ControlCenter::Ansible::Inventory.includes(:variable_sets).find_by(id: params[:id])
          end

          def persist(inventory, status: :ok)
            attributes = inventory_params
            requested_ids = attributes.delete(:variable_set_ids) if attributes.key?(:variable_set_ids)
            inventory.assign_attributes(attributes)
            variable_sets = requested_ids.nil? ? nil : resolve_variable_sets(inventory, requested_ids)
            return render_unprocessable(inventory) if requested_ids && !variable_sets

            saved = ::ControlCenter::Ansible::Inventory.transaction do
              next false unless inventory.save

              replace_variable_sets(inventory, variable_sets) if variable_sets
              true
            end

            if saved
              render json: serialize(inventory.reload), status: status
            else
              render_unprocessable(inventory)
            end
          end

          def inventory_params
            params.permit(:name, :description, :yaml_content, :default_credential_id, variable_set_ids: [])
          end

          def resolve_variable_sets(inventory, raw_ids)
            ids = normalized_ids(raw_ids)
            unless ids && ids.uniq.length == ids.length
              inventory.errors.add(:variable_set_ids, "must contain unique integer IDs")
              return
            end

            by_id = ::ControlCenter::Ansible::VariableSet.where(id: ids).index_by(&:id)
            unless by_id.length == ids.length
              inventory.errors.add(:variable_set_ids, "contains an unknown variable set")
              return
            end

            ids.map { |id| by_id.fetch(id) }
          end

          def normalized_ids(raw_ids)
            Array(raw_ids).map { |id| id.is_a?(Integer) ? id : Integer(id, 10) }
          rescue ArgumentError, TypeError
            nil
          end

          def replace_variable_sets(inventory, variable_sets)
            inventory.inventory_variable_sets.destroy_all
            variable_sets.each_with_index do |variable_set, position|
              inventory.inventory_variable_sets.create!(variable_set: variable_set, position: position)
            end
          end

          def serialize(inventory)
            {
              id: inventory.id,
              name: inventory.name,
              description: inventory.description,
              yaml_content: inventory.yaml_content,
              checksum: inventory.checksum,
              default_credential_id: inventory.default_credential_id,
              variable_set_ids: inventory.variable_sets.map(&:id),
              known_hosts_configured: inventory.known_hosts.present?,
              host_key_fingerprints: inventory.host_key_fingerprints,
              created_at: inventory.created_at,
              updated_at: inventory.updated_at
            }
          end

          def render_unprocessable(inventory)
            render json: {
              error: "unprocessable_entity", details: inventory.errors.to_hash
            }, status: :unprocessable_entity
          end

          def requested_credential
            return unless params[:credential_id].present?

            ::ControlCenter::Ansible::Credential.find_by(id: params[:credential_id])
          end

          def serialize_task(task)
            {
              id: task.id,
              kind: task.kind,
              status: task.status,
              result: task.result,
              error_code: task.error_code,
              error_detail: task.error_detail,
              started_at: task.started_at,
              completed_at: task.completed_at,
              created_at: task.created_at,
              updated_at: task.updated_at
            }
          end

          def render_task_error(error)
            render json: {
              error: "unprocessable_entity",
              details: { task: [ error.message ], code: [ error.code ] }
            }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
