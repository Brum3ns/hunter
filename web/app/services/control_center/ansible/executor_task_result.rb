module ControlCenter
  module Ansible
    module ExecutorTaskResult
      class Error < StandardError
        attr_reader :code

        def initialize(message, code: "invalid_result")
          @code = code
          super(message)
        end
      end

      class Conflict < Error
        def initialize
          super("a different terminal result is already stored", code: "result_conflict")
        end
      end

      TERMINAL_STATUSES = %w[succeeded failed canceled].freeze

      module_function

      def call(task:, runner:, lease:, result:, now: Time.current)
        normalized = normalize_result(result, kind: task.kind)

        ExecutorTask.transaction do
          task.lock!
          if task.terminal?
            verify_terminal_retry!(task, runner, normalized)
            next task
          end

          LeaseVerifier.verify!(task, runner:, lease:, statuses: [ "running" ], now:)
          task.update!(normalized.merge(
            execution_payload: nil,
            lease_digest: nil,
            lease_expires_at: nil,
            heartbeat_at: nil,
            completed_at: now
          ))
          task.reload
        end
      end

      def normalize_result(result, kind:)
        source = result.respond_to?(:to_h) ? result.to_h.stringify_keys : {}
        status = source["status"].to_s
        raise Error, "status must be terminal" unless TERMINAL_STATUSES.include?(status)
        output = source["result"] || {}
        raise Error, "result must be an object" unless output.is_a?(Hash)
        output = normalize_output(output, kind, status:)
        error_code = source["error_code"].presence
        error_detail = source["error_detail"].presence
        raise Error, "error detail is too large" if error_detail&.to_s&.bytesize.to_i > 4096

        { status:, result: output, error_code:, error_detail: error_detail&.to_s }
      end
      private_class_method :normalize_result

      def normalize_output(output, kind, status:)
        case kind
        when "host_key_scan" then normalize_scan_output(output)
        when "syntax_check" then normalize_syntax_output(output, status:)
        when "connectivity_test" then normalize_connectivity_output(output)
        else raise Error, "unsupported task kind"
        end
      end
      private_class_method :normalize_output

      def normalize_scan_output(output)
        candidates = Array(output["candidates"] || output[:candidates])
        raise Error, "too many host-key candidates" if candidates.length > 1_000

        {
          "candidates" => candidates.map do |candidate|
            source = candidate.respond_to?(:to_h) ? candidate.to_h.stringify_keys : {}
            port = source["port"]
            unless source["host"].is_a?(String) && port.is_a?(Integer) &&
                   source["known_hosts_line"].is_a?(String) && source["fingerprint"].is_a?(String)
              raise Error, "host-key candidate is invalid"
            end
            {
              "host" => source["host"],
              "port" => port,
              "known_hosts_line" => source["known_hosts_line"],
              "fingerprint" => source["fingerprint"],
              "trusted" => false
            }
          end
        }
      end
      private_class_method :normalize_scan_output

      def normalize_syntax_output(output, status:)
        return {} if output.empty? && status != "succeeded"

        valid = output.key?("valid") ? output["valid"] : output[:valid]
        errors = Array(output["errors"] || output[:errors])
        raise Error, "syntax result valid flag is required" unless valid == true || valid == false
        raise Error, "syntax errors must be strings" unless errors.all? { |error| error.is_a?(String) }

        { "valid" => valid, "errors" => errors }
      end
      private_class_method :normalize_syntax_output

      def normalize_connectivity_output(output)
        hosts = Array(output["hosts"] || output[:hosts])
        raise Error, "too many connectivity results" if hosts.length > 1_000

        {
          "hosts" => hosts.map do |host|
            source = host.respond_to?(:to_h) ? host.to_h.stringify_keys : {}
            unless source["host"].is_a?(String) && source["status"].is_a?(String)
              raise Error, "connectivity host result is invalid"
            end
            source.slice("host", "status", "error_code")
          end
        }
      end
      private_class_method :normalize_connectivity_output

      def verify_terminal_retry!(task, runner, result)
        raise Conflict unless task.runner_id == runner.id
        raise Conflict unless result.all? { |attribute, value| task.public_send(attribute) == value }
      end
      private_class_method :verify_terminal_retry!
    end
  end
end
