module Settings
  class AnsibleCredentialsController < ApplicationController
    def create
      credential = ::ControlCenter::Ansible::Credential.new(created_by: Current.user)
      update_from_params(credential)
      redirect_to settings_path(anchor: "ansible-credentials"), notice: "Ansible credential created."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path(anchor: "ansible-credentials"),
        alert: e.record.errors.full_messages.to_sentence
    end

    def update
      credential = ::ControlCenter::Ansible::Credential.find(params[:id])
      update_from_params(credential)
      redirect_to settings_path(anchor: "ansible-credentials"), notice: "Ansible credential updated."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path(anchor: "ansible-credentials"),
        alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      ::ControlCenter::Ansible::Credential.find(params[:id]).destroy!
      redirect_to settings_path(anchor: "ansible-credentials"), notice: "Ansible credential deleted."
    end

    private

    def update_from_params(credential)
      attributes = params.require(:ansible_credential).permit(
        :name, :auth_type, :username,
        :private_key, :ssh_password, :private_key_passphrase, :become_password,
        :clear_private_key, :clear_ssh_password,
        :clear_private_key_passphrase, :clear_become_password
      )
      ::ControlCenter::Ansible::CredentialUpdater.call(
        credential: credential, attributes: attributes
      )
      credential.save!
    end
  end
end
