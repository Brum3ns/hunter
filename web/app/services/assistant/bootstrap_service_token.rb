module Assistant
  module BootstrapServiceToken
    IDENTITY_NAME = "hunter-mcp".freeze

    module_function

    # Mints the MCP reader identity and writes the raw token straight to disk.
    # The raw value is never returned, logged, or printed.
    def call(path:)
      path = Pathname.new(path)
      return if path.exist?

      identity = nil
      raw = nil
      ServiceIdentity.transaction do
        ServiceIdentity.where(enabled: true, role: "mcp_reader").find_each do |existing|
          existing.update!(enabled: false, rotated_at: Time.current)
        end
        identity, raw = ServiceIdentity.generate!(name: IDENTITY_NAME, role: "mcp_reader")
      end

      write_once(path, raw)
      identity
    ensure
      raw = nil
    end

    def write_once(path, raw)
      path.dirname.mkpath
      temporary = path.dirname.join(".#{path.basename}.#{Process.pid}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o400) { |file| file.write(raw) }
      begin
        File.link(temporary.to_s, path.to_s)
      rescue Errno::EEXIST
        nil
      ensure
        temporary.unlink
      end
    end
    private_class_method :write_once
  end
end
