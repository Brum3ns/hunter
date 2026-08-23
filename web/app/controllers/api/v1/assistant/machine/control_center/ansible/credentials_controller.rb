module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            class CredentialsController < ReadController
              MAX_LIMIT = 50

              def index
                reservation = authorize_tool!(
                  "list_ansible_credential_metadata", scope: "control_center_ansible_credentials_read"
                )
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::Credential.order(:name)
                items = scope.offset((page - 1) * limit).limit(limit).map do |credential|
                  ::Assistant::Machine::ControlCenter::Ansible::ResourceProjections.credential(credential)
                end
                list_response(reservation, count: scope.count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!(
                  "get_ansible_credential_metadata", scope: "control_center_ansible_credentials_read"
                )
                credential = ::ControlCenter::Ansible::Credential.find_by(id: params[:id])
                return machine_not_found(reservation) unless credential

                detail_response(
                  reservation, key: :credential,
                  value: ::Assistant::Machine::ControlCenter::Ansible::ResourceProjections.credential(credential)
                )
              end
            end
          end
        end
      end
    end
  end
end
