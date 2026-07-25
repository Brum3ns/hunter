module ControlCenter
  module Ansible
    class ExecutorTask < ApplicationRecord
      self.table_name = "control_center_ansible_executor_tasks"

      KINDS = %w[syntax_check host_key_scan connectivity_test].freeze
      STATUSES = %w[queued running succeeded failed canceled].freeze
      TERMINAL_STATUSES = %w[succeeded failed canceled].freeze

      belongs_to :inventory, class_name: "ControlCenter::Ansible::Inventory", optional: true
      belongs_to :playbook, class_name: "ControlCenter::Ansible::Playbook", optional: true
      belongs_to :created_by, class_name: "User"
      belongs_to :runner, optional: true

      serialize :execution_payload, coder: JSON
      encrypts :execution_payload

      scope :queued, -> { where(status: "queued") }
      scope :oldest_first, -> { order(:created_at, :id) }

      validates :kind, inclusion: { in: KINDS }
      validates :status, inclusion: { in: STATUSES }
      validates :claim_deadline, presence: true

      def claimable?
        status == "queued"
      end

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end
    end
  end
end
