module Assistant
  # Classifies each provider key environment variable into one stable reason
  # code. A value's contents never leave this module: only a reason code is
  # returned.
  module ProviderCredentials
    Status = Data.define(:slug, :reason, :available)

    # Mirrors the gateway's maxSecretBytes (16 << 10) so a value this preflight
    # calls oversize is exactly a value the gateway would refuse to load.
    MAX_BYTES = 16 * 1024
    PLACEHOLDER = /\Areplace_with_/i

    module_function

    def statuses
      # Only API-key providers are classified here. A catalog entry with no
      # secret_env (the synthetic Claude Code profile) carries no credential to
      # classify and must not appear as "skipped"/"absent".
      ProviderCatalog.entries.values.select { |entry| entry.secret_env.present? }.map { |entry| status(entry) }
    end

    def available_slugs
      statuses.select(&:available).map(&:slug)
    end

    def status(entry)
      reason = reason_for(entry)
      Status.new(slug: entry.slug, reason: reason, available: reason == "valid")
    end

    # Reason codes are deliberately fewer than the file-based predecessor:
    # symlink, bad_mode and unreadable were properties of a file on a mount and
    # have no environment-variable equivalent.
    def reason_for(entry)
      raw = ENV[entry.secret_env]
      return "absent" if raw.nil?
      return "oversize" if raw.bytesize > MAX_BYTES

      body = raw.strip
      return "empty" if body.empty?
      return "placeholder" if body.match?(PLACEHOLDER)

      "valid"
    end
    private_class_method :reason_for
  end
end
