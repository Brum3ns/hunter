module ControlCenter
  module Ansible
    module RunResult
      class Error < StandardError
        attr_reader :code

        def initialize(message, code: "invalid_result")
          @code = code
          super(message)
        end
      end

      class Conflict < Error
        def initialize(message = "a different terminal result is already stored")
          super(message, code: "result_conflict")
        end
      end

      TERMINAL_STATUSES = %w[succeeded failed canceled].freeze
      ACTIVE_STATUSES = %w[validating running canceling].freeze
      COUNT_FIELDS = %w[ok_count changed_count failed_count unreachable_count].freeze
      ERROR_CODE_PATTERN = /\A[a-z0-9_]{1,64}\z/

      module_function

      def call(run:, runner:, lease:, result:, now: Time.current)
        normalized = normalize_result(result)

        Run.transaction do
          group = run.run_group
          group.lock!
          run.lock!
          if run.terminal?
            verify_terminal_retry!(run, runner, normalized)
            next run
          end

          LeaseVerifier.verify!(run, runner:, lease:, statuses: ACTIVE_STATUSES, now:)
          normalized[:error_detail] = redact_detail(normalized[:error_detail], group.execution_payload)
          run.update!(normalized.merge(
            lease_digest: nil,
            lease_expires_at: nil,
            heartbeat_at: nil,
            completed_at: now
          ))
          group.update!(
            status: normalized[:status],
            completed_at: now,
            execution_payload: nil
          )
          group.credential&.update!(last_used_at: now)
          run.reload
        end
      end

      def normalize_result(result)
        source = result.respond_to?(:to_h) ? result.to_h.stringify_keys : {}
        status = source["status"].to_s
        raise Error, "status must be terminal" unless TERMINAL_STATUSES.include?(status)

        counts = COUNT_FIELDS.index_with do |field|
          value = source[field]
          raise Error, "#{field} must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
          value
        end
        exit_status = source["exit_status"]
        raise Error, "exit_status must be an integer or null" unless exit_status.nil? || exit_status.is_a?(Integer)
        error_code = source["error_code"].presence
        raise Error, "error_code must be a string" if error_code && !error_code.is_a?(String)
        raise Error, "error_code is invalid" if error_code && !error_code.match?(ERROR_CODE_PATTERN)
        error_detail = source["error_detail"].presence
        raise Error, "error_detail must be a string" if error_detail && !error_detail.is_a?(String)
        raise Error, "error_detail is too large" if error_detail&.bytesize.to_i > 4096

        counts.symbolize_keys.merge(
          status:,
          exit_status:,
          error_code:,
          error_detail: error_detail&.to_s
        )
      end
      private_class_method :normalize_result

      def verify_terminal_retry!(run, runner, result)
        raise Conflict unless run.runner_id == runner.id

        result.each do |attribute, value|
          stored = run.public_send(attribute)
          next if attribute == :error_detail && redacted_equivalent?(stored, value)
          raise Conflict unless stored == value
        end
      end
      private_class_method :verify_terminal_retry!

      def redacted_equivalent?(stored, submitted)
        return stored == submitted unless stored.to_s.include?(SecretRedactor::FILTERED)

        fragments = stored.to_s.split(SecretRedactor::FILTERED, -1)
        pattern = fragments.map { |fragment| Regexp.escape(fragment) }.join(".+?")
        submitted.to_s.match?(Regexp.new("\\A#{pattern}\\z", Regexp::MULTILINE))
      end
      private_class_method :redacted_equivalent?

      def redact_detail(detail, payload)
        return if detail.nil?

        secrets = strings_in((payload || {})["secrets"])
        SecretRedactor.call(detail, secrets:).value
      end
      private_class_method :redact_detail

      def strings_in(value)
        case value
        when String then [ value ]
        when Array then value.flat_map { |child| strings_in(child) }
        when Hash then value.values.flat_map { |child| strings_in(child) }
        when Integer, Float, TrueClass, FalseClass then [ value.to_s ]
        else []
        end
      end
      private_class_method :strings_in
    end
  end
end
