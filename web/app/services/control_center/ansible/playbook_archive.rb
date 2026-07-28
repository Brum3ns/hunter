require "tempfile"
require "zip"

module ControlCenter
  module Ansible
    module PlaybookArchive
      class Error < StandardError; end

      MAX_PLAYBOOKS = 100
      MAX_UNCOMPRESSED_BYTES = 10.megabytes

      class Archive
        attr_reader :filename

        def initialize(tempfile, filename)
          @tempfile = tempfile
          @filename = filename
        end

        def path
          @tempfile&.path
        end

        def read
          raise Error, "archive is closed" unless @tempfile

          @tempfile.rewind
          @tempfile.read
        end

        def close!
          @tempfile&.close!
          @tempfile = nil
        end
      end

      module_function

      def call(playbooks)
        selected = playbooks.to_a
        raise Error, "select at least one playbook" if selected.empty?
        raise Error, "select at most #{MAX_PLAYBOOKS} playbooks" if selected.length > MAX_PLAYBOOKS

        bytes = selected.sum { |playbook| playbook.yaml_content.to_s.bytesize }
        if bytes > MAX_UNCOMPRESSED_BYTES
          raise Error, "selected YAML exceeds #{MAX_UNCOMPRESSED_BYTES} bytes"
        end

        tempfile = Tempfile.new([ "hunter-ansible-playbooks-", ".zip" ])
        tempfile.binmode
        write_archive(tempfile.path, selected)
        tempfile.rewind
        Archive.new(tempfile, "hunter-ansible-playbooks-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.zip")
      rescue
        tempfile&.close!
        raise
      end

      def write_archive(path, playbooks)
        used_names = {}
        Zip::OutputStream.open(path) do |zip|
          playbooks.each do |playbook|
            base = safe_basename(playbook.name)
            filename = available_filename(base, used_names)
            zip.put_next_entry(filename)
            zip.write(playbook.yaml_content.to_s)
          end
        end
      end
      private_class_method :write_archive

      def available_filename(base, used_names)
        sequence = 1
        loop do
          suffix = sequence == 1 ? "" : "-#{sequence}"
          candidate = "#{base}#{suffix}.yml"
          key = candidate.downcase
          unless used_names[key]
            used_names[key] = true
            return candidate
          end
          sequence += 1
        end
      end
      private_class_method :available_filename

      def safe_basename(name)
        stem = name.to_s.strip.sub(/\.ya?ml\z/i, "")
        safe = stem.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A[-_.]+|[-_.]+\z/, "")
        safe.presence || "playbook"
      end
      private_class_method :safe_basename
    end
  end
end
