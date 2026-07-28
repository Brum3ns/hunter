module ControlCenter
  module Templates
    module Persist
      ATTRIBUTES = %i[name kind tags description output commands target].freeze

      Result = Data.define(:record, :errors) do
        def success?
          errors.empty?
        end
      end

      module_function

      def call(record:, attributes:, user:, expected_lock_version: nil)
        attributes = permitted_attributes(attributes)

        record.class.transaction do
          if record.persisted?
            record.lock!
            return stale(record) unless expected_version?(record, expected_lock_version)
          else
            record.created_by = user&.username
          end

          record.assign_attributes(attributes)
          record.save
        end

        Result.new(record: record, errors: record.errors)
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

      def stale(record)
        record.errors.add(:base, "destination_stale")
        Result.new(record: record, errors: record.errors)
      end
      private_class_method :stale
    end
  end
end
