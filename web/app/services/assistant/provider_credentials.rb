module Assistant
  # Classifies each provider key file into one stable reason code. A file's
  # contents never leave this module: only a reason code is returned.
  module ProviderCredentials
    Status = Data.define(:slug, :reason, :available)

    DEFAULT_DIRECTORY = "/run/secrets".freeze
    MAX_BYTES = 8192
    ACCEPTED_MODES = [ 0o400, 0o600 ].freeze
    PLACEHOLDER = /\Areplace_with_/i

    module_function

    def statuses(directory: DEFAULT_DIRECTORY)
      ProviderCatalog.entries.values.map { |entry| status(entry, directory: directory) }
    end

    def available_slugs(directory: DEFAULT_DIRECTORY)
      statuses(directory: directory).select(&:available).map(&:slug)
    end

    def status(entry, directory: DEFAULT_DIRECTORY)
      reason = reason_for(entry, directory)
      Status.new(slug: entry.slug, reason: reason, available: reason == "valid")
    end

    def reason_for(entry, directory)
      path = Pathname.new(directory).join(entry.secret_file)

      begin
        info = path.lstat
      rescue Errno::ENOENT
        return "absent"
      rescue SystemCallError
        return "unreadable"
      end

      return "symlink" if info.symlink?
      return "oversize" if info.size > MAX_BYTES
      return "bad_mode" unless ACCEPTED_MODES.include?(info.mode & 0o777)

      body = begin
        path.read(MAX_BYTES).to_s
      rescue SystemCallError
        return "unreadable"
      end

      return "empty" if body.strip.empty?
      return "placeholder" if body.strip.match?(PLACEHOLDER)

      "valid"
    end
    private_class_method :reason_for
  end
end
