module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            # Read-only, grant-and-scope-gated Ansible playbook browsing for
            # the Assistant. Delegates to the same Postgres read path as the
            # public Api::V1::ControlCenter::Ansible::PlaybooksController and
            # returns only the bounded PlaybookProjection allowlist.
            class PlaybooksController < ReadController
              MAX_LIMIT = 50

              def index
                reservation = authorize_tool!("list_playbooks", scope: "control_center_ansible")
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::Playbook.order(Arel.sql("lower(name)"))
                count = scope.count
                rows = scope.offset((page - 1) * limit).limit(limit)
                items = rows.map { |playbook| ::Assistant::Machine::ControlCenter::Ansible::PlaybookProjection.summary(playbook) }
                list_response(reservation, count: count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!("get_playbook", scope: "control_center_ansible")
                playbook = ::ControlCenter::Ansible::Playbook.find_by(id: params[:id])
                return machine_not_found(reservation) unless playbook

                detail_response(
                  reservation, key: :playbook,
                  value: ::Assistant::Machine::ControlCenter::Ansible::PlaybookProjection.full(playbook)
                )
              end
            end
          end
        end
      end
    end
  end
end
