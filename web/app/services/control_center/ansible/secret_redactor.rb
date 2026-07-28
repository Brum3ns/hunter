require "json"

module ControlCenter
  module Ansible
    module SecretRedactor
      Result = Data.define(:value, :truncated, :bytes)

      FILTERED = "[FILTERED]"
      TRUNCATION_MARKER = "\n...[TRUNCATED]...\n"
      MAX_BYTES = 64.kilobytes

      module_function

      def call(value, secrets:)
        normalized_secrets = Array(secrets).filter_map do |secret|
          candidate = secret.to_s
          candidate unless candidate.empty?
        end.uniq.sort_by { |secret| -secret.bytesize }

        redacted = redact(value, normalized_secrets)
        serialized = redacted.is_a?(String) ? redacted : JSON.generate(redacted)
        return Result.new(value: redacted, truncated: false, bytes: serialized.bytesize) if serialized.bytesize <= MAX_BYTES

        truncated = truncate(serialized)
        Result.new(value: truncated, truncated: true, bytes: truncated.bytesize)
      end

      def redact(value, secrets)
        case value
        when String
          secrets.reduce(value.dup) { |text, secret| text.gsub(secret, FILTERED) }
        when Array
          value.map { |child| redact(child, secrets) }
        when Hash
          value.each_with_object({}) do |(key, child), output|
            redacted_key = secrets.include?(key.to_s) ? FILTERED : key
            output[redacted_key] = redact(child, secrets)
          end
        else
          value
        end
      end
      private_class_method :redact

      def truncate(serialized)
        available = MAX_BYTES - TRUNCATION_MARKER.bytesize
        head_bytes = (available * 0.75).floor
        tail_bytes = available - head_bytes
        head = serialized.byteslice(0, head_bytes).to_s.scrub
        tail = serialized.byteslice(-tail_bytes, tail_bytes).to_s.scrub
        "#{head}#{TRUNCATION_MARKER}#{tail}"
      end
      private_class_method :truncate
    end
  end
end
