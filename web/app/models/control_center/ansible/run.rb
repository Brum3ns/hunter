module ControlCenter
  module Ansible
    class Run < ApplicationRecord
      self.table_name = "control_center_ansible_runs"

      STATUSES = %w[waiting queued validating running succeeded failed canceling canceled skipped].freeze
      TERMINAL_STATUSES = %w[succeeded failed canceled skipped].freeze
      SNAPSHOT_ATTRIBUTES = %w[
        playbook_yaml inventory_yaml known_hosts variable_audit secret_variable_names
        playbook_name inventory_name credential_name credential_fingerprint host_limit
        check_mode timeout_seconds position
      ].freeze

      belongs_to :run_group, class_name: "ControlCenter::Ansible::RunGroup", inverse_of: :runs
      belongs_to :playbook, class_name: "ControlCenter::Ansible::Playbook", optional: true
      belongs_to :runner, optional: true
      has_many :run_events, -> { order(:counter, :id) },
        class_name: "ControlCenter::Ansible::RunEvent", dependent: :destroy, inverse_of: :run

      scope :queued, -> { where(status: "queued") }
      scope :oldest_first, -> { order(:queued_at, :id) }

      validates :status, inclusion: { in: STATUSES }
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :playbook_yaml, :inventory_yaml, :known_hosts,
        :playbook_name, :inventory_name, :credential_name, presence: true
      validates :timeout_seconds,
        numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400 }
      validate :snapshots_are_immutable, on: :update

      def claimable?
        status == "queued"
      end

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end

      private

      def snapshots_are_immutable
        SNAPSHOT_ATTRIBUTES.each do |attribute|
          errors.add(attribute, "cannot be changed after launch") if will_save_change_to_attribute?(attribute)
        end
      end
    end
  end
end
