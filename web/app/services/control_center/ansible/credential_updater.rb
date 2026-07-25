module ControlCenter
  module Ansible
    module CredentialUpdater
      PUBLIC_FIELDS = %w[name auth_type username].freeze
      SECRET_FIELDS = Credential::SECRET_FIELDS.map(&:to_s).freeze
      module_function

      def call(credential:, attributes:)
        attrs = attributes.to_h.stringify_keys
        credential.assign_attributes(attrs.slice(*PUBLIC_FIELDS))
        SECRET_FIELDS.each do |field|
          clear = ActiveModel::Type::Boolean.new.cast(attrs["clear_#{field}"])
          value = attrs[field]
          credential.public_send("#{field}=", nil) if clear
          credential.public_send("#{field}=", value) if !clear && value.present?
        end
        credential
      end
    end
  end
end
