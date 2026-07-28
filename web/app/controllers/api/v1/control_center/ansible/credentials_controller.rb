module Api
  module V1
    module ControlCenter
      module Ansible
        class CredentialsController < Api::V1::BaseController
          api_scope :control_center

          def index
            render json: { credentials: scope.map { |credential| serialize(credential) } }
          end

          def show
            credential = scope.find_by(id: params[:id])
            return render_not_found unless credential

            render json: serialize(credential)
          end

          def create
            credential = ::ControlCenter::Ansible::Credential.new(created_by: Current.user)
            persist(credential, status: :created)
          end

          def update
            credential = scope.find_by(id: params[:id])
            return render_not_found unless credential

            persist(credential)
          end

          def destroy
            credential = scope.find_by(id: params[:id])
            return render_not_found unless credential

            credential.destroy!
            head :no_content
          end

          private

          def scope
            ::ControlCenter::Ansible::Credential.order(:name)
          end

          def persist(credential, status: :ok)
            ::ControlCenter::Ansible::CredentialUpdater.call(
              credential: credential,
              attributes: params.permit(
                :name, :auth_type, :username,
                :private_key, :ssh_password, :private_key_passphrase, :become_password,
                :clear_private_key, :clear_ssh_password,
                :clear_private_key_passphrase, :clear_become_password
              )
            )
            if credential.save
              render json: serialize(credential), status: status
            else
              render json: {
                error: "unprocessable_entity",
                detail: credential.errors.full_messages
              }, status: :unprocessable_entity
            end
          end

          def serialize(credential)
            {
              id: credential.id,
              name: credential.name,
              auth_type: credential.auth_type,
              username: credential.username,
              public_key_fingerprint: credential.public_key_fingerprint,
              private_key_configured: credential.private_key_configured?,
              ssh_password_configured: credential.ssh_password_configured?,
              private_key_passphrase_configured: credential.private_key_passphrase_configured?,
              become_password_configured: credential.become_password_configured?,
              last_used_at: credential.last_used_at,
              created_at: credential.created_at,
              updated_at: credential.updated_at
            }
          end
        end
      end
    end
  end
end
