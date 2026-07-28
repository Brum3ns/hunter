module ControlCenter
  module Ansible
    class RunEvent < ApplicationRecord
      self.table_name = "control_center_ansible_run_events"

      belongs_to :run, class_name: "ControlCenter::Ansible::Run", inverse_of: :run_events
      belongs_to :runner, optional: true

      scope :oldest_first, -> { order(:counter, :id) }

      validates :event_uuid, presence: true, uniqueness: { scope: :run_id }
      validates :counter, presence: true, uniqueness: { scope: :run_id },
        numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :event_type, presence: true
    end
  end
end
