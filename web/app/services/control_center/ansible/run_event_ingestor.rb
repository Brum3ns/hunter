module ControlCenter
  module Ansible
    module RunEventIngestor
      class Error < StandardError
        attr_reader :code

        def initialize(message, code: "invalid_events")
          @code = code
          super(message)
        end
      end

      MAX_EVENTS = 100
      MAX_RUN_BYTES = 20.megabytes
      ACTIVE_STATUSES = %w[validating running canceling].freeze
      EVENT_FIELDS = %w[event_uuid parent_uuid counter event_type play task host event_time stdout event_data].freeze
      COMPARABLE_FIELDS = %w[event_uuid parent_uuid counter event_type play task host event_time stdout event_data truncated].freeze

      module_function

      def call(run:, runner:, lease:, events:, now: Time.current)
        normalized_events = normalize_batch(events)

        Run.transaction do
          run.lock!
          LeaseVerifier.verify!(run, runner:, lease:, statuses: ACTIVE_STATUSES, now:)
          secrets = secret_values(run)
          stored_bytes = run.stored_event_bytes

          records = normalized_events.map do |attributes|
            redacted, bytes = redact_event(attributes, secrets)
            existing = existing_event(run, redacted)
            if existing
              assert_identical!(existing, redacted)
              next existing
            end

            if stored_bytes + bytes > MAX_RUN_BYTES
              redacted = redacted.merge(stdout: nil, event_data: {}, truncated: true)
              bytes = 0
            end
            record = run.run_events.create!(redacted.merge(runner:))
            stored_bytes += bytes
            record
          end

          run.update!(stored_event_bytes: stored_bytes, truncated: run.truncated || records.any?(&:truncated?))
          records
        end
      end

      def normalize_batch(events)
        batch = Array(events)
        unless batch.length.between?(1, MAX_EVENTS)
          raise Error, "events must contain between 1 and #{MAX_EVENTS} items"
        end

        batch.map { |event| normalize_event(event) }
      end
      private_class_method :normalize_batch

      def normalize_event(event)
        source = event.respond_to?(:to_h) ? event.to_h.stringify_keys : {}
        event_uuid = source["event_uuid"]
        event_type = source["event_type"]
        counter = source["counter"]
        raise Error, "event_uuid is required" unless event_uuid.is_a?(String) && event_uuid.present?
        raise Error, "event_type is required" unless event_type.is_a?(String) && event_type.present?
        raise Error, "counter must be a non-negative integer" unless counter.is_a?(Integer) && counter >= 0
        raise Error, "event_data must be an object" unless source["event_data"].nil? || source["event_data"].is_a?(Hash)

        source.slice(*EVENT_FIELDS).symbolize_keys.merge(event_data: source["event_data"] || {})
      end
      private_class_method :normalize_event

      def redact_event(attributes, secrets)
        display = attributes.slice(:play, :task, :host, :stdout, :event_data)
        result = SecretRedactor.call(display, secrets:)
        if result.value.is_a?(Hash)
          redacted_display = result.value.symbolize_keys
          [ attributes.merge(redacted_display, truncated: result.truncated), result.bytes ]
        else
          [ attributes.merge(stdout: result.value, event_data: {}, truncated: true), result.bytes ]
        end
      end
      private_class_method :redact_event

      def existing_event(run, attributes)
        by_uuid = run.run_events.find_by(event_uuid: attributes[:event_uuid])
        by_counter = run.run_events.find_by(counter: attributes[:counter])
        if by_uuid && by_counter && by_uuid.id != by_counter.id
          raise Error.new("event UUID and counter identify different records", code: "event_conflict")
        end
        by_uuid || by_counter
      end
      private_class_method :existing_event

      def assert_identical!(existing, attributes)
        expected = COMPARABLE_FIELDS.index_with { |field| attributes[field.to_sym] }
        actual = existing.attributes.slice(*COMPARABLE_FIELDS)
        return if actual == expected

        raise Error.new("event identity was already used with different content", code: "event_conflict")
      end
      private_class_method :assert_identical!

      def secret_values(run)
        payload = run.run_group.execution_payload || {}
        credential_values = strings_in(payload["secrets"])
        variables = payload["variables"].is_a?(Hash) ? payload["variables"] : {}
        variable_values = run.secret_variable_names.flat_map { |name| strings_in(variables[name]) }
        (credential_values + variable_values).reject(&:empty?).uniq
      end
      private_class_method :secret_values

      def strings_in(value)
        case value
        when String then [ value ]
        when Integer, Float, TrueClass, FalseClass then [ value.to_s ]
        when Array then value.flat_map { |child| strings_in(child) }
        when Hash then value.values.flat_map { |child| strings_in(child) }
        else []
        end
      end
      private_class_method :strings_in
    end
  end
end
