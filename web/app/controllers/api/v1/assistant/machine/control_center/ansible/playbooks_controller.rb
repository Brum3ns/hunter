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

              # Approval-free create. AnsibleStatic is the sole, fail-closed
              # persist gate below — it MUST run and MUST reject (422, no
              # persist) before ControlCenter::Ansible::Playbooks::Persist is
              # ever called. Create-only: always
              # ControlCenter::Ansible::Playbook.new, never an existing record.
              def create
                reservation = authorize_tool!("create_ansible_playbook", scope: "control_center_ansible_write")
                return unless require_control_center_write_enabled!(reservation)

                begin
                  ::Assistant::RateLimiter.consume!(user: machine_user, action: "create")
                rescue ::Assistant::RateLimiter::LimitExceeded => e
                  reservation.fail!
                  return render json: { error: e.code, retry_after: e.retry_after_seconds }, status: :too_many_requests
                end

                envelope = ::Assistant::DraftEnvelope.ansible(params[:playbook])
                return render_machine_validation_error(reservation, envelope.codes) unless envelope.valid?

                result = ::Assistant::DraftValidation::AnsibleStatic.call(envelope.normalized["source"])
                return render_machine_validation_error(reservation, result.codes) unless result.valid?

                persist = ::ControlCenter::Ansible::Playbooks::Persist.call(
                  record: ::ControlCenter::Ansible::Playbook.new,
                  attributes: { name: envelope.normalized["name"], yaml_content: result.normalized }, user: machine_user
                )
                return render_machine_create_error(reservation, persist.errors) unless persist.success?

                ::Assistant::Audit.record!(event: "machine.create", attributes: {
                  correlation_id: machine_grant.turn.correlation_id, user_id: machine_user&.id,
                  target_type: "control_center_ansible_playbook", target_id: persist.record.id,
                  metadata: { operation: "create_ansible_playbook", outcome: "created" }
                })
                machine_create_response(reservation, key: :playbook, record: persist.record)
              end
            end
          end
        end
      end
    end
  end
end
