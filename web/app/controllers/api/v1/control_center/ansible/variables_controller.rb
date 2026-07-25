module Api
  module V1
    module ControlCenter
      module Ansible
        class VariablesController < Api::V1::BaseController
          api_scope :control_center

          def create
            variable_set = find_variable_set
            return render_not_found unless variable_set

            variable = variable_set.variables.build
            persist(variable, status: :created)
          end

          def update
            variable = find_variable
            return render_not_found unless variable

            persist(variable)
          end

          def destroy
            variable = find_variable
            return render_not_found unless variable

            variable.destroy!
            head :no_content
          end

          private

          def find_variable_set
            ::ControlCenter::Ansible::VariableSet.find_by(id: params[:variable_set_id])
          end

          def find_variable
            ::ControlCenter::Ansible::Variable.find_by(
              id: params[:id], variable_set_id: params[:variable_set_id]
            )
          end

          def persist(variable, status: :ok)
            return render_unprocessable(variable) unless assign_form(variable)

            if variable.save
              render json: serialize(variable), status: status
            else
              render_unprocessable(variable)
            end
          end

          def assign_form(variable)
            attributes = variable_params
            was_secret = variable.secret?
            variable.assign_attributes(attributes.slice(:name, :value_type, :secret, :position))
            value_supplied = params.key?(:value)
            value = plain_value(params[:value])
            clear_requested = attributes[:clear_value] == true

            if variable.persisted? && was_secret && !variable.secret? && (!value_supplied || value.blank?)
              variable.errors.add(:value, "must replace a secret value before making it visible")
              return false
            end

            if clear_requested && (!value_supplied || value.blank?)
              variable.serialized_value = nil
            elsif value_supplied && !(variable.persisted? && variable.secret? && value.blank?)
              variable.typed_value = value
            end
            true
          rescue ::ControlCenter::Ansible::TypedValue::Error => e
            variable.errors.add(:serialized_value, e.message)
            false
          end

          def variable_params
            params.permit(:name, :value_type, :secret, :position, :clear_value)
          end

          def plain_value(value)
            case value
            when ActionController::Parameters
              value.to_unsafe_h.transform_values { |child| plain_value(child) }
            when Array
              value.map { |child| plain_value(child) }
            else
              value
            end
          end

          def serialize(variable)
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

          def render_unprocessable(variable)
            render json: {
              error: "unprocessable_entity", details: variable.errors.to_hash
            }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
