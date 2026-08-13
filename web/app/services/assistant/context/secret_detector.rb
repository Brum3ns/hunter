module Assistant
  module Context
    module SecretDetector
      MAX_STRING_BYTES = 24_576
      CREDENTIAL_KEY = /\A(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|auth[_-]?token|session[_-]?token|private[_-]?token|token|password|passwd|secret(?:[_-]?key)?)\z/i
      PATTERNS = {
        private_key: /-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----/i,
        authorization: /\bauthorization\s*:\s*(?!\[REDACTED\](?:\s|$))\S+/i,
        cookie_header: /\b(?:cookie|set-cookie)\s*:\s*(?!\[REDACTED\](?:\s|$))\S+/i,
        credential_assignment: /\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|auth[_-]?token|session[_-]?token|private[_-]?token|token|password|passwd|secret(?:[_-]?key)?)\b\s*[:=]\s*(?!\[REDACTED\](?:\s|$))\S+/i,
        cloud_access_key: /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
        url_userinfo: %r{https?://[^\s/@:]+:[^\s/@]+@}i,
        jwt: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
        vault_block: /\$ANSIBLE_VAULT;/i,
        secret_sentinel: /\bSECRET(?:[-_][A-Z0-9]+)+\b/
      }.freeze

      module_function

      def detect(value, max_string_bytes: MAX_STRING_BYTES)
        each_string(value) do |string|
          return :invalid_encoding unless string.valid_encoding?
          return :value_too_large if string.bytesize > max_string_bytes
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
            yield "#{key}=#{child}" if child.is_a?(String) && key.to_s.match?(CREDENTIAL_KEY)
            each_string(child, &block)
          end
        end
      end
      private_class_method :each_string
    end
  end
end
