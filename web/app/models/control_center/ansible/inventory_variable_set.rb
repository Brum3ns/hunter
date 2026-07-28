module ControlCenter
  module Ansible
    class InventoryVariableSet < ApplicationRecord
      self.table_name = "control_center_ansible_inventory_variable_sets"

      belongs_to :inventory, class_name: "ControlCenter::Ansible::Inventory",
        inverse_of: :inventory_variable_sets
      belongs_to :variable_set, class_name: "ControlCenter::Ansible::VariableSet",
        inverse_of: :inventory_variable_sets

      validates :variable_set_id, uniqueness: { scope: :inventory_id }
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    end
  end
end
