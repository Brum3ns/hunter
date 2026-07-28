module Assistant
  class ContextReference < ApplicationRecord
    RESOURCE_TYPES = %w[
      program
      target
      cve
      vulnerability
      whiterabbit_template
      ansible_playbook
    ].freeze

    self.table_name = "assistant_context_references"

    belongs_to :turn, class_name: "Assistant::Turn", inverse_of: :context_references

    validates :resource_type, inclusion: { in: RESOURCE_TYPES }
    validates :resource_id, presence: true, length: { maximum: 255 },
      uniqueness: { scope: %i[turn_id resource_type] }
    validates :label, presence: true, length: { maximum: 255 }
    validates :serializer_version, inclusion: { in: %w[v1] }
    validate :reference_is_immutable, on: :update

    private

    def reference_is_immutable
      %i[turn_id resource_type resource_id serializer_version].each do |attribute|
        errors.add(attribute.to_s.delete_suffix("_id").to_sym, "cannot be changed") if
          will_save_change_to_attribute?(attribute)
      end
    end
  end
end
