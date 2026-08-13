module Assistant
  module Machine
    module SensitiveData
      MAX_TEXT_BYTES = 16_384
      MAX_PAYLOAD_TEXT_BYTES = 65_536
      MAX_HEADERS = 50
      MAX_HEADER_NAME = 200
      MAX_HEADER_VALUE = 4_096
      SENSITIVE_HEADERS = %w[
        authorization proxy-authorization cookie set-cookie x-api-key api-key
        x-auth-token x-access-token
      ].to_set.freeze
      SAFE_RESPONSE_HEADERS = %w[
        server content-type content-length location cache-control etag last-modified
        x-powered-by x-frame-options content-security-policy strict-transport-security
        access-control-allow-origin access-control-allow-methods access-control-allow-headers
        via x-cache x-request-id
      ].to_set.freeze
      SENSITIVE_KEYS = /\A(?:authorization|proxy_authorization|cookie|set_cookie|api_key|access_token|refresh_token|id_token|client_secret|auth_token|session_token|private_token|token|password|passwd|secret|secret_key|private_key|private_key_passphrase|ssh_password|become_password)\z/i
      PRIVATE_OR_CLOUD = /-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\$ANSIBLE_VAULT;/i
      CREDENTIAL_ASSIGNMENT = /\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|auth[_-]?token|session[_-]?token|private[_-]?token|token|password|passwd|secret(?:[_-]?key)?)\b\s*[:=]\s*\S+/i
      SENSITIVE_HEADER_LINE = /^([^\r\n]*?\b(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-auth-token|x-access-token)[ \t]*:).*$/i
      URL_USERINFO = %r{(https?://)[^\s/@:]+:[^\s/@]+@}i
      JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/
      SECRET_SENTINEL = /\bSECRET(?:[-_][A-Z0-9]+)+\b/

      Result = Data.define(:value, :redacted)

      module_function

      def text(value, max_bytes: MAX_TEXT_BYTES)
        return Result.new(value: nil, redacted: true) unless safe_source?(value)
        return Result.new(value: nil, redacted: true) if value.match?(PRIVATE_OR_CLOUD)

        sanitized = value.dup
        redacted = false
        sanitized.gsub!(SENSITIVE_HEADER_LINE) do
          redacted = true
          "#{Regexp.last_match(1)} [REDACTED]"
        end
        sanitized.gsub!(CREDENTIAL_ASSIGNMENT) do
          redacted = true
          "[REDACTED]"
        end
        sanitized.gsub!(URL_USERINFO) do
          redacted = true
          "#{Regexp.last_match(1)}[REDACTED]@"
        end
        sanitized.gsub!(JWT) do
          redacted = true
          "[REDACTED]"
        end
        return Result.new(value: nil, redacted: true) if sanitized.match?(SECRET_SENTINEL)

        if sanitized.bytesize > max_bytes
          sanitized = sanitized.byteslice(0, max_bytes).to_s.scrub
          redacted = true
        end
        return Result.new(value: nil, redacted: true) if
          Assistant::Context::SecretDetector.detect(sanitized, max_string_bytes: max_bytes)

        Result.new(value: sanitized, redacted: redacted)
      end

      # Applies the same secret sanitizer to every string value in a completed
      # read payload. Projections remain closed field allowlists; this is the
      # final cross-module defense so a newly exposed text field cannot bypass
      # the secret boundary by forgetting a projection-local helper.
      def payload(value, max_bytes: MAX_PAYLOAD_TEXT_BYTES)
        redacted = [ false ]
        budget = [ 20_000 ]
        sanitized = sanitize_payload_value(value, max_bytes, redacted, budget, {})
        Result.new(value: sanitized, redacted: redacted.first)
      rescue SystemStackError
        Result.new(value: nil, redacted: true)
      end

      def headers(value)
        closed_headers(value)
      end

      def response_headers(value)
        closed_headers(value, allowed_names: SAFE_RESPONSE_HEADERS | SENSITIVE_HEADERS)
      end

      def json(value)
        return Result.new(value: nil, redacted: true) if sensitive_structure?(value, [ 10_000 ], {})

        text(JSON.generate(value))
      rescue JSON::GeneratorError, EncodingError
        Result.new(value: nil, redacted: true)
      end

      def closed_headers(value, allowed_names: nil)
        return [] unless value.is_a?(Hash)

        value.filter_map do |raw_name, raw_value|
          name = raw_name.to_s
          next unless safe_header_name?(name)
          next if allowed_names && !allowed_names.include?(name.downcase)

          if SENSITIVE_HEADERS.include?(name.downcase)
            { "name" => name, "value" => nil, "redacted" => true }
          else
            result = text(raw_value.to_s, max_bytes: MAX_HEADER_VALUE)
            { "name" => name, "value" => result.value, "redacted" => result.redacted }
          end
        end.first(MAX_HEADERS)
      end
      private_class_method :closed_headers

      def sensitive_structure?(value, budget, seen)
        budget[0] -= 1
        return true if budget[0].negative?

        case value
        when Hash
          return true if seen[value.object_id]

          seen[value.object_id] = true
          value.any? do |key, child|
            key.to_s.tr("-", "_").match?(SENSITIVE_KEYS) || sensitive_structure?(child, budget, seen)
          end
        when Array
          return true if seen[value.object_id]

          seen[value.object_id] = true
          value.any? { |child| sensitive_structure?(child, budget, seen) }
        else
          false
        end
      ensure
        seen.delete(value.object_id) if value.is_a?(Hash) || value.is_a?(Array)
      end
      private_class_method :sensitive_structure?

      def sanitize_payload_value(value, max_bytes, redacted, budget, seen)
        budget[0] -= 1
        raise SystemStackError if budget[0].negative?

        case value
        when String
          result = text(value, max_bytes: max_bytes)
          redacted[0] ||= result.redacted
          result.value || "[REDACTED]"
        when Hash
          raise SystemStackError if seen[value.object_id]

          seen[value.object_id] = true
          value.each_with_object({}) do |(key, child), output|
            if key.to_s.tr("-", "_").match?(SENSITIVE_KEYS)
              redacted[0] = true
              output[key] = "[REDACTED]"
            else
              output[key] = sanitize_payload_value(child, max_bytes, redacted, budget, seen)
            end
          end
        when Array
          raise SystemStackError if seen[value.object_id]

          seen[value.object_id] = true
          value.map { |child| sanitize_payload_value(child, max_bytes, redacted, budget, seen) }
        else
          value
        end
      ensure
        seen.delete(value.object_id) if value.is_a?(Hash) || value.is_a?(Array)
      end
      private_class_method :sanitize_payload_value

      def safe_source?(value)
        value.is_a?(String) && value.valid_encoding? &&
          value.each_codepoint.none? { |codepoint| (codepoint < 32 || codepoint == 127) && ![ 9, 10, 13 ].include?(codepoint) }
      end
      private_class_method :safe_source?

      def safe_header_name?(name)
        name.present? && name.length <= MAX_HEADER_NAME && name.valid_encoding? &&
          name.match?(/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/)
      end
      private_class_method :safe_header_name?
    end
  end
end
