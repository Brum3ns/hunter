module Assistant
  module DraftValidation
    module Whiterabbit
      VALIDATION_VERSION = "whiterabbit-v1"

      module_function

      def call(attributes)
        parsed = Assistant::DraftEnvelope.whiterabbit(attributes)
        return result(false, parsed.codes, parsed.messages) unless parsed.valid?

        allowlist = Array(ControlCenter::TemplateValidator.allowlist).map(&:to_s).reject(&:blank?).uniq
        if allowlist.empty?
          return result(false,
            [ "assistant_command_policy_unconfigured" ],
            [ "Assistant command policy is not configured." ])
        end

        disallowed = parsed.normalized.fetch("commands").each_index.select do |index|
          !allowlist.include?(parsed.normalized.dig("commands", index, "command"))
        end
        if disallowed.any?
          return result(false,
            Array.new(disallowed.length, "assistant_command_not_allowed"),
            disallowed.map { |index| "Command #{index + 1} is not permitted by assistant policy." })
        end

        domain_errors = ControlCenter::TemplateValidator.call(parsed.normalized.fetch("commands"))
        if domain_errors.any?
          return result(false,
            [ "whiterabbit_template_invalid" ],
            [ "Draft does not satisfy the Whiterabbit template policy." ])
        end

        result(true, [], [], parsed.normalized)
      end

      def result(valid, codes, messages, normalized = nil)
        Assistant::DraftValidation::Result.new(
          valid: valid,
          codes: codes.freeze,
          messages: messages.freeze,
          normalized: normalized,
          validation_version: VALIDATION_VERSION
        )
      end
      private_class_method :result
    end
  end
end
