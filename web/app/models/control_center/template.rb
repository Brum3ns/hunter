module ControlCenter
  # A Whiterabbit command template. Postgres is the source of truth; on job
  # submit it is rendered to a Whiterabbit cmdscript YAML (see TemplateRenderer).
  class Template < ApplicationRecord
    self.table_name = "control_center_templates"

    KINDS = %w[cmdscript workflow].freeze

    validates :name, presence: true, uniqueness: true
    validates :kind, inclusion: { in: KINDS }
    validate :commands_pass_validator

    private

    def commands_pass_validator
      ControlCenter::TemplateValidator.call(commands).each { |m| errors.add(:commands, m) }
    end
  end
end
