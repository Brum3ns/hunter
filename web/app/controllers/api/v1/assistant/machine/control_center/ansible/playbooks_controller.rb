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

              # Approval-free authoring. AnsibleStatic is the sole, fail-closed
              # persist gate below — it MUST run and MUST reject (422, no
              # persist) before ControlCenter::Ansible::Playbooks::Persist is
              # ever called. Create always uses a new record; update is a
              # separate explicit tool and requires the expected lock version.
              def create
                reservation = authorize_tool!("create_ansible_playbook", scope: "control_center_ansible_write")
                return unless require_control_center_write_enabled!(reservation)
                return unless consume_authoring_rate!(reservation, action: "create")
                input = ::Assistant::Machine::ControlCenter::ArtifactInput.ansible_create(params[:playbook])
                return render_machine_validation_error(reservation, input.codes) unless input.valid?

                result = ::Assistant::DraftValidation::AnsibleStatic.call(input.normalized["source"])
                return render_machine_validation_error(reservation, result.codes) unless result.valid?

                persist = persist_and_audit_machine_authoring(
                  reservation: reservation,
                  event: "machine.create", operation: "create_ansible_playbook",
                  target_type: "control_center_ansible_playbook"
                ) do
                  ::ControlCenter::Ansible::Playbooks::Persist.call(
                    record: ::ControlCenter::Ansible::Playbook.new,
                    attributes: persistence_attributes(input.normalized, result.normalized), user: machine_user
                  )
                end
                return render_machine_create_error(reservation, persist.errors) unless persist.success?

                machine_create_response(reservation, key: :playbook, record: persist.record)
              end

			  def update
				reservation = authorize_tool!("edit_ansible_playbook", scope: "control_center_ansible_edit")
				return unless require_control_center_write_enabled!(reservation)
				return unless consume_authoring_rate!(reservation, action: "edit")
				expected_lock_version = machine_expected_lock_version(reservation)
				return if expected_lock_version.nil?
				playbook = ::ControlCenter::Ansible::Playbook.includes(:variable_sets).find_by(id: params[:id])
				return render_machine_artifact_not_found(reservation) unless playbook

				changes = ::Assistant::Machine::ControlCenter::ArtifactInput.ansible_changes(params[:changes])
				return render_machine_validation_error(reservation, changes.codes) unless changes.valid?
				candidate = ::Assistant::Machine::ControlCenter::ArtifactInput.ansible_create(
				  current_attributes(playbook).merge(changes.normalized)
				)
				return render_machine_validation_error(reservation, candidate.codes) unless candidate.valid?
				validation = ::Assistant::DraftValidation::AnsibleStatic.call(candidate.normalized["source"])
				return render_machine_validation_error(reservation, validation.codes) unless validation.valid?

				persist = persist_and_audit_machine_authoring(
				  reservation: reservation,
				  event: "machine.edit", operation: "edit_ansible_playbook",
				  target_type: "control_center_ansible_playbook"
				) do
				  ::ControlCenter::Ansible::Playbooks::Persist.call(
				    record: playbook, attributes: persistence_attributes(candidate.normalized, validation.normalized),
				    user: machine_user, expected_lock_version: expected_lock_version
				  )
				end
				return render_machine_persist_error(reservation, persist.errors) unless persist.success?
				machine_edit_response(reservation, key: :playbook, record: persist.record)
			  end

			  private

			  def persistence_attributes(attributes, normalized_source)
				{
				  name: attributes["name"], description: attributes["description"],
				  yaml_content: normalized_source,
				  variable_set_ids: attributes["variable_set_ids"]
				}.compact
			  end

			  def current_attributes(playbook)
				attributes = {
				  "name" => playbook.name,
				  "source" => playbook.yaml_content,
				  "variable_set_ids" => playbook.variable_sets.map(&:id)
				}
				attributes["description"] = playbook.description if playbook.description
				attributes
			  end
            end
          end
        end
      end
    end
  end
end
