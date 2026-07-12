module Api
  module V1
    module ControlCenter
      # CRUD over ControlCenter::Template plus dry-run /validate (structured) and
      # /validate_yaml (raw YAML). A `yaml` param on create/update is parsed by
      # TemplateYaml into structured attrs; the model's TemplateValidator still
      # runs, so the command allowlist can't be bypassed via YAML.
      class TemplatesController < BaseController
        def index
          templates = ::ControlCenter::Template.order(:name)
          render json: { templates: templates.map { |t| serialize(t) } }
        end

        def show
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          render json: serialize(template)
        end

        def create
          attrs, yaml_errors = build_attrs
          return render_yaml_errors(yaml_errors) if yaml_errors.any?
          template = ::ControlCenter::Template.new(attrs.merge("created_by" => Current.user&.username))
          return render_unprocessable(template) unless template.save
          render json: serialize(template), status: :created
        end

        def update
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          attrs, yaml_errors = build_attrs
          return render_yaml_errors(yaml_errors) if yaml_errors.any?
          return render_unprocessable(template) unless template.update(attrs)
          render json: serialize(template)
        end

        def destroy
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          template.destroy
          head :no_content
        end

        def validate
          attrs = template_params
          errors = ::ControlCenter::TemplateValidator.call(attrs["commands"])
          yaml = ::ControlCenter::TemplateRenderer.to_yaml(::ControlCenter::Template.new(attrs))
          render json: { valid: errors.empty?, errors: errors, yaml: yaml }
        end

        def validate_yaml
          attrs, errors = ::ControlCenter::TemplateYaml.parse(params[:yaml])
          errors = errors.dup
          errors.concat(::ControlCenter::TemplateValidator.call(attrs["commands"])) if attrs
          render json: { valid: errors.empty?, errors: errors, template: attrs }
        end

        private

        # [attrs, errors] — from raw YAML when a `yaml` param is present, else from
        # the structured params. YAML parse errors short-circuit before the model.
        def build_attrs
          if params[:yaml].present?
            attrs, errors = ::ControlCenter::TemplateYaml.parse(params[:yaml])
            [attrs || {}, errors]
          else
            [template_params.to_h, []]
          end
        end

        def template_params
          params.permit(:name, :kind, :description, :output,
                        tags: [],
                        commands: [:command, :operator, { args: [] }],
                        target: [:type, :separator, :output]).to_h
        end

        def serialize(t)
          {
            id: t.id, name: t.name, kind: t.kind, tags: t.tags,
            description: t.description, output: t.output, commands: t.commands,
            target: t.target, created_by: t.created_by,
            yaml: ::ControlCenter::TemplateRenderer.to_yaml(t),
            created_at: t.created_at, updated_at: t.updated_at
          }
        end

        def render_unprocessable(record)
          render json: { error: "unprocessable_entity", detail: record.errors.full_messages }, status: :unprocessable_entity
        end

        def render_yaml_errors(errors)
          render json: { error: "unprocessable_entity", detail: errors }, status: :unprocessable_entity
        end
      end
    end
  end
end
