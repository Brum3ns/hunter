module ControlCenter
  module Ansible
    class VariableSet < ApplicationRecord
      self.table_name = "control_center_ansible_variable_sets"

      belongs_to :created_by, class_name: "User", inverse_of: :control_center_ansible_variable_sets
      has_many :variables, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :variable_set
      has_many :playbook_variable_sets, dependent: :destroy, inverse_of: :variable_set
      has_many :playbooks, through: :playbook_variable_sets
      has_many :inventory_variable_sets, dependent: :destroy, inverse_of: :variable_set
      has_many :inventories, through: :inventory_variable_sets

      before_validation :normalize_name

      validates :name, presence: true, uniqueness: { case_sensitive: false }

      private

      def normalize_name
        self.name = name.to_s.strip
      end
    end
  end
end
