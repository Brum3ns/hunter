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
              reservation = authorize_tool!("list_templates", scope: "control_center_templates")
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
              reservation = authorize_tool!("get_template", scope: "control_center_templates")
              template = ::ControlCenter::Template.find_by(id: params[:id])
              return machine_not_found(reservation) unless template

              detail_response(reservation, key: :template, value: ::Assistant::Machine::ControlCenter::TemplateProjection.full(template))
            end

            # Approval-free authoring. DraftValidation is the sole, fail-closed
            # persist gate below — it MUST run and MUST reject (422, no
            # persist) before ControlCenter::Templates::Persist is ever
            # called. Create always uses ControlCenter::Template.new; a
            # duplicate name is rejected, never overwritten. Update is a
            # separate explicit tool and requires the expected lock version.
            def create
              reservation = authorize_tool!("create_whiterabbit_template", scope: "control_center_templates_write")
              return unless require_control_center_write_enabled!(reservation)
              return unless consume_authoring_rate!(reservation, action: "create")

              input = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(params[:template])
              return render_machine_validation_error(reservation, input.codes) unless input.valid?
              result = validate_whiterabbit(input.normalized)
              return render_machine_validation_error(reservation, result.codes) unless result.valid?

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

              machine_create_response(reservation, key: :template, record: persist.record)
            end

			def update
			  reservation = authorize_tool!("edit_whiterabbit_template", scope: "control_center_templates_edit")
			  return unless require_control_center_write_enabled!(reservation)
			  return unless consume_authoring_rate!(reservation, action: "edit")
			  expected_lock_version = machine_expected_lock_version(reservation)
			  return if expected_lock_version.nil?
			  template = ::ControlCenter::Template.find_by(id: params[:id])
			  return render_machine_artifact_not_found(reservation) unless template

			  changes = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_changes(params[:changes])
			  return render_machine_validation_error(reservation, changes.codes) unless changes.valid?
			  candidate = ::Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(
				current_attributes(template).merge(changes.normalized)
			  )
			  return render_machine_validation_error(reservation, candidate.codes) unless candidate.valid?
			  validation = validate_whiterabbit(candidate.normalized)
			  return render_machine_validation_error(reservation, validation.codes) unless validation.valid?

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
			  machine_edit_response(reservation, key: :template, record: persist.record)
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
