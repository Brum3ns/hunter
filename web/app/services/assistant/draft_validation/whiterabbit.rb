module Assistant
  module DraftValidation
    module Whiterabbit
      VALIDATION_VERSION = "whiterabbit-v2"

      module_function

      def call(attributes)
        parsed = Assistant::DraftEnvelope.whiterabbit(attributes)
        return result(false, parsed.codes, parsed.messages) unless parsed.valid?
        if Assistant::Context::SecretDetector.detect(parsed.normalized)
          return result(false,
            [ "artifact_secret_material_not_allowed" ],
            [ "Draft contains prohibited secret material." ])
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
