module Assistant
  module Context
    module SecretDetector
      MAX_STRING_BYTES = 24_576
      PATTERNS = {
        private_key: /-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----/i,
        authorization: /\bauthorization\s*:\s*(?:bearer|basic)\s+\S+/i,
        credential_assignment: /\b(?:api[_-]?key|access[_-]?token|token|password|passwd|secret)\b\s*[:=]\s*\S+/i,
        cloud_access_key: /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
        url_userinfo: %r{https?://[^\s/@:]+:[^\s/@]+@}i,
        vault_block: /\$ANSIBLE_VAULT;/i
      }.freeze

      module_function

      def detect(value)
        each_string(value) do |string|
          return :invalid_encoding unless string.valid_encoding?
          return :value_too_large if string.bytesize > MAX_STRING_BYTES
          return :control_character if string.each_codepoint.any? do |codepoint|
            (codepoint < 32 || codepoint == 127) && ![ 9, 10, 13 ].include?(codepoint)
          end

          match = PATTERNS.find { |_name, pattern| string.match?(pattern) }
          return match.first if match
        end
        nil
      end

      def safe?(value)
        detect(value).nil?
      end

      def each_string(value, &block)
        case value
        when String
          yield value
        when Array
          value.each { |child| each_string(child, &block) }
        when Hash
          value.each do |key, child|
            yield key.to_s
            each_string(child, &block)
          end
        end
      end
      private_class_method :each_string
    end
  end
end
