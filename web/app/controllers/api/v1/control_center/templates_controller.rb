module Api
  module V1
    module ControlCenter
      # CRUD over ControlCenter::Template plus a dry-run /validate. Validation is
      # enforced by the model (and re-checked at submit); unknown commands are
      # rejected with 422.
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
          template = ::ControlCenter::Template.new(template_params.merge(created_by: Current.user&.username))
          return render_unprocessable(template) unless template.save
          render json: serialize(template), status: :created
        end

        def update
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          return render_unprocessable(template) unless template.update(template_params)
          render json: serialize(template)
        end

        def destroy
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          template.destroy
          head :no_content
        end

        def validate
          errors = ::ControlCenter::TemplateValidator.call(commands_param)
          render json: { valid: errors.empty?, errors: errors }
        end

        private

        def template_params
          params.permit(:name, :kind, :description, :output,
                        tags: [],
                        commands: [:command, :operator, { args: [] }],
                        target: [:type, :separator, :output]).to_h
        end

        def commands_param
          params.permit(commands: [:command, :operator, { args: [] }]).to_h["commands"]
        end

        def serialize(t)
          {
            id: t.id, name: t.name, kind: t.kind, tags: t.tags,
            description: t.description, output: t.output, commands: t.commands,
            target: t.target, created_by: t.created_by,
            created_at: t.created_at, updated_at: t.updated_at
          }
        end

        def render_unprocessable(record)
          render json: { error: "unprocessable_entity", detail: record.errors.full_messages }, status: :unprocessable_entity
        end
      end
    end
  end
end
