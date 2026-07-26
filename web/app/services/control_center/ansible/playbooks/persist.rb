module ControlCenter
  module Ansible
    module Playbooks
      module Persist
        ATTRIBUTES = %i[name description yaml_content variable_set_ids].freeze

        Result = Data.define(:record, :errors) do
          def success?
            errors.empty?
          end
        end

        module_function

        def call(record:, attributes:, user:, expected_lock_version: nil)
          attributes = permitted_attributes(attributes)
          requested_ids = attributes.delete(:variable_set_ids) if attributes.key?(:variable_set_ids)

          record.class.transaction do
            if record.persisted?
              record.lock!
              return stale(record) unless expected_version?(record, expected_lock_version)
            else
              record.created_by = user
            end

            variable_sets = requested_ids.nil? ? nil : resolve_variable_sets(record, requested_ids)
            return result(record) if requested_ids && !variable_sets

            record.assign_attributes(attributes)
            return result(record) unless record.save

            replace_variable_sets(record, variable_sets) if variable_sets
          end

          result(record)
        end

        def permitted_attributes(attributes)
          attributes.to_h.deep_symbolize_keys.slice(*ATTRIBUTES)
        end
        private_class_method :permitted_attributes

        def expected_version?(record, expected)
          expected.nil? || record.lock_version == Integer(expected.to_s, 10)
        rescue ArgumentError, TypeError
          false
        end
        private_class_method :expected_version?

        def resolve_variable_sets(record, raw_ids)
          ids = normalized_ids(raw_ids)
          unless ids && ids.uniq.length == ids.length
            record.errors.add(:variable_set_ids, "must contain unique integer IDs")
            return
          end

          by_id = ControlCenter::Ansible::VariableSet.where(id: ids).index_by(&:id)
          unless by_id.length == ids.length
            record.errors.add(:variable_set_ids, "contains an unknown variable set")
            return
          end

          ids.map { |id| by_id.fetch(id) }
        end
        private_class_method :resolve_variable_sets

        def normalized_ids(raw_ids)
          Array(raw_ids).map { |id| id.is_a?(Integer) ? id : Integer(id, 10) }
        rescue ArgumentError, TypeError
          nil
        end
        private_class_method :normalized_ids

        def replace_variable_sets(record, variable_sets)
          record.playbook_variable_sets.destroy_all
          variable_sets.each_with_index do |variable_set, position|
            record.playbook_variable_sets.create!(variable_set: variable_set, position: position)
          end
        end
        private_class_method :replace_variable_sets

        def stale(record)
          record.errors.add(:base, "destination_stale")
          result(record)
        end
        private_class_method :stale

        def result(record)
          Result.new(record: record, errors: record.errors)
        end
        private_class_method :result
      end
    end
  end
end
