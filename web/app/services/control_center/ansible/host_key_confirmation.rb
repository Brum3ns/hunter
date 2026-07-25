require "base64"
require "digest"

module ControlCenter
  module Ansible
    module HostKeyConfirmation
      class Error < StandardError
        attr_reader :code

        def initialize(message, code: "invalid_host_key")
          @code = code
          super(message)
        end
      end

      module_function

      def call(inventory:, candidates:)
        targets = ExecutorTaskBuilder.targets_for(inventory)
        confirmed = Array(candidates).map { |candidate| confirm_candidate(candidate, targets) }
        raise Error, "at least one candidate is required" if confirmed.empty?

        Inventory.transaction do
          inventory.lock!
          lines = existing_lines(inventory.known_hosts)
          confirmed.each do |candidate|
            lines.reject! { |line| line_matches_candidate?(line, candidate) }
            lines << candidate.fetch(:known_hosts_line)
          end
          fingerprints = inventory.host_key_fingerprints.deep_dup
          confirmed.each do |candidate|
            fingerprints[fingerprint_key(candidate)] = candidate.fetch(:fingerprint)
          end
          inventory.update!(known_hosts: lines.join("\n"), host_key_fingerprints: fingerprints)
          inventory
        end
      end

      def confirm_candidate(raw_candidate, targets)
        source = raw_candidate.respond_to?(:to_h) ? raw_candidate.to_h.symbolize_keys : {}
        host = source[:host].to_s
        port = integer_port(source[:port])
        target = targets.find { |item| item["host"] == host && item["port"] == port }
        raise Error, "candidate is not an inventory target" unless target

        scanned = normalize_fingerprint(source[:scanned_fingerprint])
        expected = normalize_fingerprint(source[:expected_fingerprint])
        unless secure_equal?(scanned, expected)
          raise Error.new("scanned fingerprint does not match expected fingerprint", code: "fingerprint_mismatch")
        end

        line = source[:known_hosts_line].to_s.strip
        derived = fingerprint_from_line(line, target, port)
        unless secure_equal?(derived, scanned)
          raise Error.new("known-host line does not match its fingerprint", code: "fingerprint_mismatch")
        end

        { host:, address: target["address"], port:, known_hosts_line: line, fingerprint: scanned }
      end
      private_class_method :confirm_candidate

      def integer_port(value)
        port = value.is_a?(Integer) ? value : Integer(value.to_s, 10)
        raise Error, "port is invalid" unless port.between?(1, 65_535)
        port
      rescue ArgumentError, TypeError
        raise Error, "port is invalid"
      end
      private_class_method :integer_port

      def normalize_fingerprint(value)
        fingerprint = value.to_s.strip
        fingerprint = "SHA256:#{fingerprint}" unless fingerprint.start_with?("SHA256:")
        raise Error, "fingerprint is required" if fingerprint == "SHA256:"
        fingerprint
      end
      private_class_method :normalize_fingerprint

      def fingerprint_from_line(line, target, port)
        host_field, key_type, encoded_key, = line.split
        unless host_field && key_type&.match?(/\A(?:ssh-|ecdsa-)/) && encoded_key
          raise Error, "known-host line is invalid"
        end
        allowed_hosts = [ target["host"], target["address"] ].flat_map do |name|
          port == 22 ? [ name, "[#{name}]:22" ] : [ "[#{name}]:#{port}" ]
        end
        tokens = host_field.split(",")
        raise Error, "known-host line is for a different host" if (tokens & allowed_hosts).empty?

        key_blob = Base64.strict_decode64(encoded_key)
        digest = Base64.strict_encode64(Digest::SHA256.digest(key_blob)).delete_suffix("=")
        "SHA256:#{digest}"
      rescue ArgumentError
        raise Error, "known-host line key is invalid"
      end
      private_class_method :fingerprint_from_line

      def secure_equal?(left, right)
        left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
      end
      private_class_method :secure_equal?

      def existing_lines(known_hosts)
        known_hosts.to_s.lines.map(&:strip).reject(&:empty?)
      end
      private_class_method :existing_lines

      def line_matches_candidate?(line, candidate)
        host_field = line.split.first.to_s
        names = [ candidate.fetch(:host), candidate.fetch(:address) ]
        expected = names.flat_map do |name|
          candidate.fetch(:port) == 22 ? [ name, "[#{name}]:22" ] : [ "[#{name}]:#{candidate.fetch(:port)}" ]
        end
        (host_field.split(",") & expected).any?
      end
      private_class_method :line_matches_candidate?

      def fingerprint_key(candidate)
        "#{candidate.fetch(:host)}:#{candidate.fetch(:port)}"
      end
      private_class_method :fingerprint_key
    end
  end
end
