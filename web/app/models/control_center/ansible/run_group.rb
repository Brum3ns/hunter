module ControlCenter
  module Ansible
    class RunGroup < ApplicationRecord
      self.table_name = "control_center_ansible_run_groups"

      STATUSES = %w[queued running succeeded failed partially_succeeded canceling canceled].freeze
      EXECUTION_MODES = %w[sequential parallel].freeze
      FAILURE_POLICIES = %w[stop continue].freeze
      TERMINAL_STATUSES = %w[succeeded failed partially_succeeded canceled].freeze

      belongs_to :inventory, class_name: "ControlCenter::Ansible::Inventory", optional: true
      belongs_to :credential, class_name: "ControlCenter::Ansible::Credential", optional: true
      belongs_to :created_by, class_name: "User"
      has_many :runs, -> { order(:position, :id) },
        class_name: "ControlCenter::Ansible::Run", dependent: :destroy, inverse_of: :run_group

      serialize :execution_payload, coder: JSON
      encrypts :execution_payload

      validates :status, inclusion: { in: STATUSES }
      validates :execution_mode, inclusion: { in: EXECUTION_MODES }
      validates :failure_policy, inclusion: { in: FAILURE_POLICIES }
      validates :concurrency_limit,
        numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 20 }
      validate :launch_snapshot_is_immutable, on: :update

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end

      private

      def launch_snapshot_is_immutable
        return unless will_save_change_to_launch_snapshot?

        errors.add(:launch_snapshot, "cannot be changed after launch")
      end
    end
  end
end
