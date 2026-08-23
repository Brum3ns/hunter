module Assistant
  module Machine
    module ControlCenter
      module JobInput
        Result = Data.define(:success, :attributes, :codes) do
          def success? = success
        end

        ROOT_KEYS = %w[template queue_name selections targets target_chunk delay].freeze
        SELECTION_KEYS = %w[source q ids exclude_ids].freeze
        MAX_SELECTIONS = 100
        MAX_IDS = 10_000
        MAX_TARGETS = 10_000

        module_function

        def call(value, require_template:)
          input = closed_hash(value)
          return failure("assistant_job_input_invalid") unless input
          return failure("assistant_unknown_input") if (input.keys - ROOT_KEYS).any?

          template = input["template"]
          if require_template && !(template.is_a?(String) && template.present? && template.bytesize <= 255)
            return failure("assistant_job_template_invalid")
          end
          queue = input.fetch("queue_name", "test")
          return failure("assistant_job_queue_invalid") unless queue.is_a?(String) && queue.match?(/\A[a-zA-Z0-9._-]{1,100}\z/)
          selections = normalize_selections(input.fetch("selections", []))
          return failure("assistant_job_selections_invalid") unless selections
          targets = input.fetch("targets", [])
          return failure("assistant_job_targets_invalid") unless targets.is_a?(Array) && targets.length <= MAX_TARGETS &&
            targets.all? { |target| target.is_a?(String) && target.present? && target.bytesize <= 8_192 }
          chunk = input.fetch("target_chunk", 0)
          delay = input.fetch("delay", 0)
          return failure("assistant_job_limits_invalid") unless chunk.is_a?(Integer) && chunk.between?(0, 1_000_000) &&
            delay.is_a?(Integer) && delay.between?(0, 86_400_000)

          normalized = {
            "template" => template,
            "queue_name" => queue,
            "selections" => selections,
            "targets" => targets.map(&:strip).reject(&:empty?).uniq,
            "target_chunk" => chunk,
            "delay" => delay
          }
          return failure("assistant_secret_input_denied") unless
            Assistant::Context::SecretDetector.safe?(normalized) &&
              !Assistant::Machine::SensitiveData.payload(normalized).redacted

          Result.new(success: true, attributes: normalized.freeze, codes: [])
        end

        def normalize_selections(value)
          return unless value.is_a?(Array) && value.length <= MAX_SELECTIONS

          value.map do |raw|
            selection = closed_hash(raw)
            return unless selection && (selection.keys - SELECTION_KEYS).empty?
            source = selection["source"]
            q = selection["q"]
            ids = selection.fetch("ids", [])
            exclude_ids = selection.fetch("exclude_ids", [])
            return unless ::ControlCenter::TargetSelection::SOURCES.include?(source) &&
              (q.nil? || (q.is_a?(String) && q.bytesize <= 500)) &&
              valid_ids?(ids) && valid_ids?(exclude_ids)
            { "source" => source, "q" => q, "ids" => ids.uniq, "exclude_ids" => exclude_ids.uniq }
          end
        end
        private_class_method :normalize_selections

        def valid_ids?(value)
          value.is_a?(Array) && value.length <= MAX_IDS &&
            value.all? { |id| id.is_a?(String) && id.present? && id.bytesize <= 255 }
        end
        private_class_method :valid_ids?

        def closed_hash(value)
          raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
          raw.is_a?(Hash) ? raw.deep_stringify_keys : nil
        end
        private_class_method :closed_hash

        def failure(code)
          Result.new(success: false, attributes: nil, codes: [ code ])
        end
        private_class_method :failure
      end
    end
  end
end
