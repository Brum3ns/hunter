require "digest"

module ControlCenter
  module Ansible
    class Inventory < ApplicationRecord
      self.table_name = "control_center_ansible_inventories"
      VALIDATOR = ControlCenter::Ansible::InventoryValidator

      belongs_to :created_by, class_name: "User", inverse_of: :control_center_ansible_inventories
      belongs_to :default_credential, class_name: "ControlCenter::Ansible::Credential",
        optional: true, inverse_of: :default_inventories
      has_many :inventory_variable_sets, -> { order(:position, :id) },
        dependent: :destroy, inverse_of: :inventory
      has_many :variable_sets, through: :inventory_variable_sets

      before_validation :normalize_name
      before_validation :set_checksum

      validates :name, presence: true, uniqueness: { case_sensitive: false }
      validates :yaml_content, presence: true
      validate :yaml_is_safe

      private

      def normalize_name
        self.name = name.to_s.strip
      end

      def set_checksum
        self.checksum = Digest::SHA256.hexdigest(yaml_content.to_s)
      end

      def yaml_is_safe
        return if yaml_content.blank?

        VALIDATOR.call(yaml_content).errors.each do |message|
          errors.add(:yaml_content, message)
        end
      end
    end
  end
end
