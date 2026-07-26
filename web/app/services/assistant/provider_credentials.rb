module Assistant
  # Classifies each provider key file into one stable reason code. A file's
  # contents never leave this module: only a reason code is returned.
  module ProviderCredentials
    Status = Data.define(:slug, :reason, :available)

    DEFAULT_DIRECTORY = "/run/secrets".freeze
    # Mirrors the gateway's maxSecretBytes (16 << 10) so a key this preflight
    # calls oversize is exactly a key the gateway would refuse to load.
    MAX_BYTES = 16 * 1024
    # enabled? runs on every assistant request, every settings page render, and
    # every 5 seconds in the event consumer, so reason_for must not copy up to
    # MAX_BYTES of live key material into a Ruby String on each call. Deciding
    # empty vs placeholder vs valid never needs more than a short prefix: the
    # PLACEHOLDER pattern is anchored at the start of the body, and emptiness
    # only needs to find one non-whitespace byte. 128 bytes is ample for both.
    # The oversize decision is unaffected — it is already made from lstat size,
    # before any read happens.
    PREFIX_BYTES = 128
    # The gateway is the enforcement point for key file modes. It additionally
    # requires a 0600 file to sit on a genuinely read-only mount (it proves this
    # by checking that a write-open fails with EROFS/EACCES). This module does
    # not replicate that probe, so it is deliberately the more permissive of the
    # two: a 0600 key on a writable mount reads as valid here and is still
    # rejected there. The read-only mount is guaranteed by the compose contract.
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
      # Size precedes mode so both are decided from lstat metadata before any
      # read; between the two, size wins only because it is the cheaper fact,
      # and either way the file is rejected without being opened.
      return "oversize" if info.size > MAX_BYTES
      return "bad_mode" unless ACCEPTED_MODES.include?(info.mode & 0o777)

      body = begin
        path.read(PREFIX_BYTES).to_s
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
