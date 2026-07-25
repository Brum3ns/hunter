module ControlCenter
  module Ansible
    class Variable < ApplicationRecord
      self.table_name = "control_center_ansible_variables"

      VALUE_TYPES = %w[string number boolean list dictionary].freeze

      belongs_to :variable_set, class_name: "ControlCenter::Ansible::VariableSet",
        inverse_of: :variables

      encrypts :serialized_value

      before_validation { self.name = name.to_s.strip }

      validates :name, presence: true,
        format: { with: /\A[A-Za-z_][A-Za-z0-9_]*\z/ },
        uniqueness: { scope: :variable_set_id }
      validates :value_type, inclusion: { in: VALUE_TYPES }
      validates :serialized_value, presence: true
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validate :serialized_value_is_typed
      validate :name_is_not_reserved_for_connection_credentials

      def typed_value
        ControlCenter::Ansible::TypedValue.load(serialized_value, type: value_type)
      end

      def typed_value=(value)
        self.serialized_value = ControlCenter::Ansible::TypedValue.dump(value, type: value_type)
      end

      private

      def serialized_value_is_typed
        return if serialized_value.blank? || VALUE_TYPES.exclude?(value_type)

        typed_value
      rescue ControlCenter::Ansible::TypedValue::Error => e
        errors.add(:serialized_value, e.message)
      end

      def name_is_not_reserved_for_connection_credentials
        return unless ControlCenter::Ansible::YamlLimits::VARIABLE_RESERVED_CONNECTION_KEYS.include?(name.to_s.downcase)

        errors.add(:name, "is reserved for connection credentials")
      end
    end
  end
end
