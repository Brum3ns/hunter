module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          # Read-only, grant-and-scope-gated Whiterabbit template browsing for
          # the Assistant. Delegates to the same Postgres read path as the
          # public Api::V1::ControlCenter::TemplatesController and returns
          # only the bounded TemplateProjection allowlist.
          class TemplatesController < ReadController
            MAX_LIMIT = 50
            FILTERS = %i[kind].freeze

            def index
              reservation = authorize_tool!("list_templates", scope: "control_center_templates_read")
              filters = params.permit(*FILTERS).to_h
              page = machine_page
              limit = machine_limit(MAX_LIMIT)
              scope = filtered_scope(filters)
              count = scope.count
              rows = scope.offset((page - 1) * limit).limit(limit)
              items = rows.map { |template| ::Assistant::Machine::ControlCenter::TemplateProjection.summary(template) }
              list_response(reservation, count: count, page: page, limit: limit, items: items)
            end

            def show
              reservation = authorize_tool!("get_template", scope: "control_center_templates_read")
              template = ::ControlCenter::Template.find_by(id: params[:id])
              return machine_not_found(reservation) unless template

              detail_response(reservation, key: :template, value: ::Assistant::Machine::ControlCenter::TemplateProjection.full(template))
            end

            def analyze
              reservation = authorize_tool!("analyze_templates", scope: "control_center_templates_read")
              body = exact_machine_body(reservation, %w[kind])
              return unless body
              scope = filtered_scope(body)
              count = scope.count
              rows = scope.limit(::Assistant::Machine::WorkflowAnalysis::MAX_ROWS).to_a
              payload = ::Assistant::Machine::WorkflowAnalysis.templates(rows, count: count)
              complete_read_response!(reservation,
                { correlation_id: machine_correlation_id }.merge(payload))
            end

            def validate
              reservation = authorize_tool!(
                "validate_whiterabbit_template", scope: "control_center_templates_read"
              )
              body = exact_machine_body(reservation, %w[template])
              return unless body
              input = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(body["template"])
              result = input.valid? ? validate_whiterabbit(input.normalized) : nil
              codes = input.valid? ? result.codes : input.codes
              complete_read_response!(reservation, {
                correlation_id: machine_correlation_id,
                valid: codes.empty?, codes: codes
              })
            end

            def validate_yaml
              reservation = authorize_tool!(
                "validate_whiterabbit_yaml", scope: "control_center_templates_read"
              )
              body = exact_machine_body(reservation, %w[yaml])
              return unless body
              unless body["yaml"].is_a?(String) && body["yaml"].bytesize <= 65_536 &&
                  Assistant::Context::SecretDetector.safe?(body["yaml"])
                return render_machine_validation_error(reservation, [ "whiterabbit_yaml_invalid" ])
              end
              attributes, yaml_errors = ::ControlCenter::TemplateYaml.parse(body["yaml"])
              input = yaml_errors.empty? ?
                ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(attributes) : nil
              result = input&.valid? ? validate_whiterabbit(input.normalized) : nil
              codes = if yaml_errors.any?
                [ "whiterabbit_yaml_invalid" ]
              elsif !input.valid?
                input.codes
              else
                result.codes
              end
              complete_read_response!(reservation, {
                correlation_id: machine_correlation_id,
                valid: codes.empty?, codes: codes
              })
            end

            # Approval-free authoring. DraftValidation is the sole, fail-closed
            # persist gate below — it MUST run and MUST reject (422, no
            # persist) before ControlCenter::Templates::Persist is ever
            # called. Create always uses ControlCenter::Template.new; a
            # duplicate name is rejected, never overwritten. Update is a
            # separate explicit tool and requires the expected lock version.
            def create
              tool = "create_whiterabbit_template"
              reservation = authorize_tool!(tool, scope: "control_center_templates_write")
              return unless require_control_center_write_enabled!(reservation)
              body = exact_machine_body(reservation, %w[template])
              return unless body

              input = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(body["template"])
              return render_machine_validation_error(reservation, input.codes) unless input.valid?
              result = validate_whiterabbit(input.normalized)
              return render_machine_validation_error(reservation, result.codes) unless result.valid?

              idempotency_key = machine_idempotency_key(tool, input.normalized)
              return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
              return unless consume_machine_effect!(reservation)

              persist = persist_and_audit_machine_authoring(
                reservation: reservation,
                event: "machine.create", operation: "create_whiterabbit_template",
                target_type: "control_center_whiterabbit_template"
              ) do
                ::ControlCenter::Templates::Persist.call(
                  record: ::ControlCenter::Template.new,
                  attributes: input.normalized.merge(result.normalized), user: machine_user
                )
              end
              return render_machine_create_error(reservation, persist.errors) unless persist.success?

              receipt = issue_machine_receipt(
                tool: tool, status: "created", target_type: "whiterabbit_template",
                target_id: persist.record.id, idempotency_key: idempotency_key
              )
              complete_machine_effect!(reservation, receipt: receipt, status: :created)
            end

            def update
              tool = "edit_whiterabbit_template"
              reservation = authorize_tool!(tool, scope: "control_center_templates_edit")
              return unless require_control_center_write_enabled!(reservation)
              body = exact_machine_body(reservation, %w[expected_lock_version changes])
              return unless body
              expected_lock_version = machine_expected_lock_version(reservation)
              return if expected_lock_version.nil?
              template = ::ControlCenter::Template.find_by(id: params[:id])
              return render_machine_artifact_not_found(reservation) unless template

              changes = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_changes(body["changes"])
              return render_machine_validation_error(reservation, changes.codes) unless changes.valid?
              candidate = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(
                current_attributes(template).merge(changes.normalized)
              )
              return render_machine_validation_error(reservation, candidate.codes) unless candidate.valid?
              validation = validate_whiterabbit(candidate.normalized)
              return render_machine_validation_error(reservation, validation.codes) unless validation.valid?
              idempotency_key = machine_idempotency_key(tool, {
                "id" => params[:id].to_s, "expected_lock_version" => expected_lock_version,
                "changes" => changes.normalized
              })
              return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
              return unless consume_machine_effect!(reservation)

              persist = persist_and_audit_machine_authoring(
                reservation: reservation,
                event: "machine.edit", operation: "edit_whiterabbit_template",
                target_type: "control_center_whiterabbit_template"
              ) do
                ::ControlCenter::Templates::Persist.call(
                  record: template, attributes: candidate.normalized.merge(validation.normalized),
                  user: machine_user, expected_lock_version: expected_lock_version
                )
              end
              return render_machine_persist_error(reservation, persist.errors) unless persist.success?
              receipt = issue_machine_receipt(
                tool: tool, status: "updated", target_type: "whiterabbit_template",
                target_id: persist.record.id, idempotency_key: idempotency_key
              )
              complete_machine_effect!(reservation, receipt: receipt)
            end

            private

            def filtered_scope(filters)
              scope = ::ControlCenter::Template.order(:name)
              scope = scope.where(kind: filters[:kind]) if filters[:kind].present?
              scope
            end

            def validate_whiterabbit(attributes)
              ::Assistant::DraftValidation::Whiterabbit.call(
                attributes.slice("name", "kind", "description", "commands")
              )
            end

            def current_attributes(template)
              attributes = {
                "name" => template.name, "kind" => template.kind,
                "tags" => template.tags.deep_dup, "description" => template.description,
                "commands" => template.commands.deep_dup
              }
              attributes["output"] = template.output if template.output
              attributes["target"] = template.target.deep_dup if template.target
              attributes
            end
          end
        end
      end
    end
  end
end
