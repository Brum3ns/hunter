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
                reservation = authorize_tool!("list_playbooks", scope: "control_center_ansible_read")
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::Playbook.order(Arel.sql("lower(name)"))
                count = scope.count
                rows = scope.offset((page - 1) * limit).limit(limit)
                items = rows.map { |playbook| ::Assistant::Machine::ControlCenter::Ansible::PlaybookProjection.summary(playbook) }
                list_response(reservation, count: count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!("get_playbook", scope: "control_center_ansible_read")
                playbook = ::ControlCenter::Ansible::Playbook.find_by(id: params[:id])
                return machine_not_found(reservation) unless playbook

                detail_response(
                  reservation, key: :playbook,
                  value: ::Assistant::Machine::ControlCenter::Ansible::PlaybookProjection.full(playbook)
                )
              end

              def analyze
                reservation = authorize_tool!("analyze_playbooks", scope: "control_center_ansible_read")
                body = exact_machine_body(reservation, [])
                return unless body
                scope = ::ControlCenter::Ansible::Playbook.includes(:created_by, :variable_sets)
                  .order(Arel.sql("lower(name)"))
                count = scope.count
                rows = scope.limit(::Assistant::Machine::WorkflowAnalysis::MAX_ROWS).to_a
                complete_machine_response!(reservation, {
                  correlation_id: machine_grant.turn.correlation_id
                }.merge(::Assistant::Machine::WorkflowAnalysis.playbooks(rows, count: count)))
              end

              def validate
                reservation = authorize_tool!("validate_ansible_playbook", scope: "control_center_ansible_read")
                body = exact_machine_body(reservation, %w[yaml_content])
                return unless body
                source = body["yaml_content"]
                unless source.is_a?(String) && source.bytesize <= ::Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES
                  return render_machine_validation_error(reservation, [ "ansible_source_invalid" ])
                end
                result = ::Assistant::DraftValidation::AnsibleStatic.call(source)
                complete_machine_response!(reservation, {
                  correlation_id: machine_grant.turn.correlation_id,
                  valid: result.valid?, codes: result.codes
                })
              end

              def export
                tool = "export_ansible_playbooks"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_playbooks_export")
                body = exact_machine_body(reservation, %w[ids])
                return unless body
                ids = body["ids"]
                unless ids.is_a?(Array) && ids.any? &&
                    ids.length <= ::ControlCenter::Ansible::PlaybookArchive::MAX_PLAYBOOKS &&
                    ids.uniq.length == ids.length && ids.all? { |id| id.is_a?(Integer) && id.positive? }
                  return render_machine_validation_error(reservation, [ "ansible_export_ids_invalid" ])
                end
                idempotency_key = machine_idempotency_key(tool, ids: ids)
                replay = ::Assistant::ActionReceipt.replay(
                  grant: machine_grant, tool: tool, idempotency_key: idempotency_key
                )
                if replay
                  artifact = ::Assistant::ExportArtifact.find_by(id: replay.dig("target", "id"), user: machine_user)
                  return complete_export_response(reservation, replay, artifact) if artifact&.expires_at&.future?
                end

                playbooks = ::ControlCenter::Ansible::Playbook.where(id: ids).index_by(&:id)
                return machine_not_found(reservation) unless playbooks.length == ids.length
                return unless consume_machine_effect!(reservation)
                artifact = ::Assistant::Machine::ControlCenter::Ansible::PlaybookExport.call(
                  user: machine_user, playbooks: ids.map { |id| playbooks.fetch(id) }
                )
                receipt = issue_machine_receipt(
                  tool: tool, status: "exported", target_type: "assistant_export_artifact",
                  target_id: artifact.id, idempotency_key: idempotency_key
                )
                complete_export_response(reservation, receipt, artifact, status: :created)
              rescue ::ControlCenter::Ansible::PlaybookArchive::Error
                render_machine_validation_error(reservation, [ "ansible_export_invalid" ])
              end

              # Approval-free authoring. AnsibleStatic is the sole, fail-closed
              # persist gate below — it MUST run and MUST reject (422, no
              # persist) before ControlCenter::Ansible::Playbooks::Persist is
              # ever called. Create always uses a new record; update is a
              # separate explicit tool and requires the expected lock version.
              def create
                tool = "create_ansible_playbook"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_write")
                return unless require_control_center_write_enabled!(reservation)
                body = exact_machine_body(reservation, %w[playbook])
                return unless body
                input = ::Assistant::Machine::ControlCenter::ArtifactInput.ansible_create(body["playbook"])
                return render_machine_validation_error(reservation, input.codes) unless input.valid?

                result = ::Assistant::DraftValidation::AnsibleStatic.call(input.normalized["source"])
                return render_machine_validation_error(reservation, result.codes) unless result.valid?

                idempotency_key = machine_idempotency_key(tool, input.normalized)
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)

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

                receipt = issue_machine_receipt(
                  tool: tool, status: "created", target_type: "ansible_playbook",
                  target_id: persist.record.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt, status: :created)
              end

              def update
                tool = "edit_ansible_playbook"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_edit")
                return unless require_control_center_write_enabled!(reservation)
                body = exact_machine_body(reservation, %w[expected_lock_version changes])
                return unless body
                expected_lock_version = machine_expected_lock_version(reservation)
                return if expected_lock_version.nil?
                playbook = ::ControlCenter::Ansible::Playbook.includes(:variable_sets).find_by(id: params[:id])
                return render_machine_artifact_not_found(reservation) unless playbook

                changes = ::Assistant::Machine::ControlCenter::ArtifactInput.ansible_changes(body["changes"])
                return render_machine_validation_error(reservation, changes.codes) unless changes.valid?
                candidate = ::Assistant::Machine::ControlCenter::ArtifactInput.ansible_create(
                  current_attributes(playbook).merge(changes.normalized)
                )
                return render_machine_validation_error(reservation, candidate.codes) unless candidate.valid?
                validation = ::Assistant::DraftValidation::AnsibleStatic.call(candidate.normalized["source"])
                return render_machine_validation_error(reservation, validation.codes) unless validation.valid?
                idempotency_key = machine_idempotency_key(tool, {
                  id: playbook.id, expected_lock_version: expected_lock_version, changes: changes.normalized
                })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)

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
                receipt = issue_machine_receipt(
                  tool: tool, status: "updated", target_type: "ansible_playbook",
                  target_id: persist.record.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              end

        private

        def complete_export_response(reservation, receipt, artifact, status: :ok)
        return machine_not_found(reservation) unless artifact
        payload = {
          correlation_id: machine_grant.turn.correlation_id,
          receipt: receipt.merge("artifact" => artifact.safe_metadata)
        }
        reservation.complete_write!(bytes: JSON.generate(payload).bytesize)
        set_grant_budget_headers
        render json: payload, status: status
        end

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
