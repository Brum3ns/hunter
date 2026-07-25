module Api
  module V1
    module ControlCenter
      module Ansible
        class VariableSetsController < Api::V1::BaseController
          api_scope :control_center

          def index
            variable_sets = ::ControlCenter::Ansible::VariableSet
              .includes(:variables).order(Arel.sql("LOWER(name) ASC"), :id)
            render json: { variable_sets: variable_sets.map { |variable_set| serialize(variable_set) } }
          end

          def show
            variable_set = find_variable_set
            return render_not_found unless variable_set

            render json: serialize(variable_set)
          end

          def create
            variable_set = ::ControlCenter::Ansible::VariableSet.new(
              variable_set_params.merge(created_by: Current.user)
            )
            persist(variable_set, status: :created)
          end

          def update
            variable_set = find_variable_set
            return render_not_found unless variable_set

            variable_set.assign_attributes(variable_set_params)
            persist(variable_set)
          end

          def destroy
            variable_set = find_variable_set
            return render_not_found unless variable_set

            variable_set.destroy!
            head :no_content
          end

          private

          def find_variable_set
            ::ControlCenter::Ansible::VariableSet.includes(:variables).find_by(id: params[:id])
          end

          def variable_set_params
            params.permit(:name, :description)
          end

          def persist(variable_set, status: :ok)
            if variable_set.save
              render json: serialize(variable_set.reload), status: status
            else
              render json: {
                error: "unprocessable_entity", details: variable_set.errors.to_hash
              }, status: :unprocessable_entity
            end
          end

          def serialize(variable_set)
            {
              id: variable_set.id,
              name: variable_set.name,
              description: variable_set.description,
              variables: variable_set.variables.map { |variable| serialize_variable(variable) },
              created_at: variable_set.created_at,
              updated_at: variable_set.updated_at
            }
          end

          def serialize_variable(variable)
            {
              id: variable.id,
              name: variable.name,
              value_type: variable.value_type,
              secret: variable.secret,
              configured: variable.serialized_value.present?,
              value: variable.secret? ? nil : variable.typed_value,
              position: variable.position
            }
          end
        end
      end
    end
  end
end
