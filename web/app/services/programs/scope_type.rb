module Programs
  # Canonical asset-type taxonomy. Each upstream platform invents its own
  # vocabulary for the same logical asset: HackerOne uses
  # GOOGLE_PLAY_APP_ID, Intigriti uses "Android", YesWeHack uses
  # "mobile-application-android", BugBountyCH uses lowercase "android".
  # Asking the user to tick five "android"-shaped checkboxes would be
  # absurd, so the sidebar offers a single canonical bucket per concept
  # and the filter pipeline expands a canonical pick into every raw
  # token that maps to it.
  module ScopeType
    # Ordered for stable sidebar presentation. Keep most-common first.
    CANONICAL = [
      :web,
      :wildcard,
      :api,
      :android,
      :ios,
      :mobile,
      :cidr,
      :executable,
      :hardware,
      :source,
      :other
    ].freeze

    LABELS = {
      web:         "Web / URL",
      wildcard:    "Wildcard",
      api:         "API",
      android:     "Android",
      ios:         "iOS",
      mobile:      "Mobile (other)",
      cidr:        "IP range",
      executable:  "Executable",
      hardware:    "Hardware / Device",
      source:      "Source code",
      other:       "Other"
    }.freeze

    # Raw upstream tokens that fold into each canonical bucket. Compared
    # case-insensitively. Any token not listed falls into :other.
    RAW_TOKENS = {
      web: %w[
        URL DOMAIN WEB WEBSITE WEB_APPLICATION WEB-APPLICATION
        web-application web_application website domain
      ],
      wildcard: %w[
        WILDCARD Wildcard wildcard
      ],
      api: %w[
        API api API_ENDPOINT api-endpoint
      ],
      android: %w[
        GOOGLE_PLAY_APP_ID Android android ANDROID
        MOBILE_ANDROID mobile-application-android MOBILE-ANDROID
        ANDROID_APP_ID
      ],
      ios: %w[
        APPLE_STORE_APP_ID iOS IOS ios
        MOBILE_IOS mobile-application-ios MOBILE-IOS
        IOS_APP_ID
      ],
      mobile: %w[
        MOBILE Mobile mobile MOBILE_APP mobile-application
        mobile-app mobile_app
      ],
      cidr: %w[
        CIDR ip-range IP_RANGE IPRANGE IP-Range
        IP\ range IP_ADDRESS_RANGE
      ],
      executable: %w[
        EXECUTABLE Executable executable BINARY binary
        DOWNLOADABLE downloadable
      ],
      hardware: %w[
        HARDWARE Hardware hardware Device DEVICE device
        IOT iot SMART_DEVICE smart-device
      ],
      source: %w[
        SOURCE_CODE source-code source_code SOURCE source code
        REPO repository repo
      ]
    }.freeze

    # Build a reverse index once: lowercased raw token → canonical key.
    REVERSE = RAW_TOKENS.each_with_object({}) do |(canon, tokens), h|
      tokens.each { |t| h[t.to_s.downcase] = canon }
    end.freeze

    module_function

    # Canonical key for an upstream type token, or :other if unrecognized.
    def canonical_for(raw)
      key = raw.to_s.downcase.strip
      return :other if key.empty?
      REVERSE[key] || :other
    end

    # Canonical keys present in the given list of program PORO instances.
    # Always returns a subset of CANONICAL, preserving canonical order.
    def canonicals_present(programs)
      seen = Set.new
      programs.each do |p|
        p.scope.each { |s| seen << canonical_for(s["type"]) }
      end
      CANONICAL & seen.to_a
    end

    # Expand a list of canonical keys (symbols or strings) into the raw
    # upstream tokens those buckets cover. Used by the filter pipeline so
    # Mongo's $in / Ruby's include? still match the on-disk values.
    def expand(canonicals)
      keys = Array(canonicals).map { |k| k.to_s.to_sym }.select { |k| RAW_TOKENS.key?(k) }
      keys.flat_map { |k| RAW_TOKENS[k] }
    end

    def label_for(canonical)
      LABELS[canonical.to_s.to_sym] || canonical.to_s
    end
  end
end
