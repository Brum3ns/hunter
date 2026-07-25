module Api
  module V1
    module ControlCenter
      module Ansible
        class PlaybooksController < Api::V1::BaseController
          api_scope :control_center

          def index
            playbooks = ::ControlCenter::Ansible::Playbook
              .includes(:variable_sets).order(Arel.sql("LOWER(name) ASC"), :id)
            render json: { playbooks: playbooks.map { |playbook| serialize(playbook) } }
          end

          def show
            playbook = find_playbook
            return render_not_found unless playbook

            render json: serialize(playbook)
          end

          def create
            playbook = ::ControlCenter::Ansible::Playbook.new(created_by: Current.user)
            persist(playbook, status: :created)
          end

          def update
            playbook = find_playbook
            return render_not_found unless playbook

            persist(playbook)
          end

          def destroy
            playbook = find_playbook
            return render_not_found unless playbook

            playbook.destroy!
            head :no_content
          end

          def validate
            result = ::ControlCenter::Ansible::PlaybookValidator.call(params[:yaml_content])
            render json: { valid: result.valid?, errors: result.errors }
          end

          def export
            ids = normalized_ids(params.permit(ids: [])[:ids])
            return render_export_error("must contain integer IDs") unless ids

            ids = ids.uniq
            return render_export_error("must select at least one playbook") if ids.empty?
            if ids.length > ::ControlCenter::Ansible::PlaybookArchive::MAX_PLAYBOOKS
              return render_export_error("must select at most 100 playbooks")
            end

            by_id = ::ControlCenter::Ansible::Playbook.where(id: ids).index_by(&:id)
            return render_not_found unless by_id.length == ids.length

            archive = ::ControlCenter::Ansible::PlaybookArchive.call(ids.map { |id| by_id.fetch(id) })
            send_data archive.read,
              filename: archive.filename,
              type: "application/zip",
              disposition: "attachment"
          rescue ::ControlCenter::Ansible::PlaybookArchive::Error => e
            render_export_error(e.message)
          ensure
            archive&.close!
          end

          private

          def find_playbook
            ::ControlCenter::Ansible::Playbook.includes(:variable_sets).find_by(id: params[:id])
          end

          def persist(playbook, status: :ok)
            attributes = playbook_params
            requested_ids = attributes.delete(:variable_set_ids) if attributes.key?(:variable_set_ids)
            playbook.assign_attributes(attributes)
            variable_sets = requested_ids.nil? ? nil : resolve_variable_sets(playbook, requested_ids)
            return render_unprocessable(playbook) if requested_ids && !variable_sets

            saved = ::ControlCenter::Ansible::Playbook.transaction do
              next false unless playbook.save

              replace_variable_sets(playbook, variable_sets) if variable_sets
              true
            end

            if saved
              render json: serialize(playbook.reload), status: status
            else
              render_unprocessable(playbook)
            end
          end

          def playbook_params
            params.permit(:name, :description, :yaml_content, variable_set_ids: [])
          end

          def resolve_variable_sets(playbook, raw_ids)
            ids = normalized_ids(raw_ids)
            unless ids && ids.uniq.length == ids.length
              playbook.errors.add(:variable_set_ids, "must contain unique integer IDs")
              return
            end

            by_id = ::ControlCenter::Ansible::VariableSet.where(id: ids).index_by(&:id)
            unless by_id.length == ids.length
              playbook.errors.add(:variable_set_ids, "contains an unknown variable set")
              return
            end

            ids.map { |id| by_id.fetch(id) }
          end

          def normalized_ids(raw_ids)
            Array(raw_ids).map { |id| id.is_a?(Integer) ? id : Integer(id, 10) }
          rescue ArgumentError, TypeError
            nil
          end

          def replace_variable_sets(playbook, variable_sets)
            playbook.playbook_variable_sets.destroy_all
            variable_sets.each_with_index do |variable_set, position|
              playbook.playbook_variable_sets.create!(variable_set: variable_set, position: position)
            end
          end

          def serialize(playbook)
            {
              id: playbook.id,
              name: playbook.name,
              description: playbook.description,
              yaml_content: playbook.yaml_content,
              checksum: playbook.checksum,
              variable_set_ids: playbook.variable_sets.map(&:id),
              created_at: playbook.created_at,
              updated_at: playbook.updated_at
            }
          end

          def render_unprocessable(playbook)
            render json: {
              error: "unprocessable_entity", details: playbook.errors.to_hash
            }, status: :unprocessable_entity
          end

          def render_export_error(message)
            render json: {
              error: "unprocessable_entity", details: { ids: [ message ] }
            }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
