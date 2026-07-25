module ControlCenter
  module Ansible
    class PlaybookVariableSet < ApplicationRecord
      self.table_name = "control_center_ansible_playbook_variable_sets"

      belongs_to :playbook, class_name: "ControlCenter::Ansible::Playbook",
        inverse_of: :playbook_variable_sets
      belongs_to :variable_set, class_name: "ControlCenter::Ansible::VariableSet",
        inverse_of: :playbook_variable_sets

      validates :variable_set_id, uniqueness: { scope: :playbook_id }
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    end
  end
end
