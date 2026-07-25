module ControlCenter
  module Ansible
    class Credential < ApplicationRecord
      self.table_name = "control_center_ansible_credentials"

      AUTH_TYPES = %w[private_key password].freeze
      SECRET_FIELDS = %i[private_key ssh_password private_key_passphrase become_password].freeze

      belongs_to :created_by, class_name: "User", inverse_of: :control_center_ansible_credentials
      has_many :default_inventories, class_name: "ControlCenter::Ansible::Inventory",
        foreign_key: :default_credential_id, dependent: :nullify, inverse_of: :default_credential

      encrypts(*SECRET_FIELDS)

      before_validation { self.name = name.to_s.strip }

      validates :name, presence: true, uniqueness: { case_sensitive: false }
      validates :username, presence: true
      validates :auth_type, inclusion: { in: AUTH_TYPES }
      validates :private_key, :ssh_password, :private_key_passphrase, :become_password,
        length: { maximum: 64.kilobytes }, allow_nil: true
      validate :required_auth_secret
      validate :derive_fingerprint, if: :private_key_changed_for_validation?

      SECRET_FIELDS.each do |field|
        define_method("#{field}_configured?") { public_send(field).present? }
      end

      private

      def required_auth_secret
        if auth_type == "private_key" && private_key.blank?
          errors.add(:private_key, "must be configured")
        elsif auth_type == "password" && ssh_password.blank?
          errors.add(:ssh_password, "must be configured")
        end
      end

      def private_key_changed_for_validation?
        auth_type == "private_key" && private_key.present? &&
          (new_record? || will_save_change_to_auth_type? || will_save_change_to_private_key? ||
            will_save_change_to_private_key_passphrase?)
      end

      def derive_fingerprint
        result = CredentialFingerprint.call(private_key: private_key, passphrase: private_key_passphrase)
        if result.error
          errors.add(:private_key, result.error)
        else
          self.public_key_fingerprint = result.fingerprint
        end
      end
    end
  end
end
