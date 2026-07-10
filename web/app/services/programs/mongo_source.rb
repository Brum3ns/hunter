module Programs
  # Read/index wiring for the programs MongoDB collection (populated by the
  # Scope Go CLI, keyed on `_sid`). Thin wrapper over the collection-agnostic
  # HunterMongo so the ported Query/Source services only reference this module.
  #
  # The collection name is configurable via MONGO_PROGRAMS_COLLECTION (wired in
  # docker-compose), mirroring how the vulnerabilities module reads
  # MONGO_COLLECTION. It defaults to "scope" — the collection the Scope CLI
  # writes programs into.
  module MongoSource
    module_function

    COLLECTION = ENV.fetch("MONGO_PROGRAMS_COLLECTION", "scope")

    # Field names track the JSON keys scope emits (some TitleCase upstream, e.g.
    # the report-bucket counters — mirrored verbatim so sorts/filters hit them).
    INDEXES = [
      { key: { _sid: 1 },                          unique: true, name: "sid_unique" },
      { key: { platform: 1 },                                    name: "platform" },
      { key: { public: 1 },                                      name: "public" },
      { key: { bounty: 1 },                                      name: "bounty" },
      { key: { vdp: 1 },                                         name: "vdp" },
      { key: { collaboration: 1 },                               name: "collaboration" },
      { key: { bounty_min: -1 },                                 name: "bounty_min" },
      { key: { bounty_max: -1 },                                 name: "bounty_max" },
      { key: { reward_avg: -1 },                                 name: "reward_avg" },
      { key: { reward_max: -1 },                                 name: "reward_max" },
      { key: { report_count: -1 },                               name: "report_count" },
      { key: { Total_reports_last24_hours: -1 },                 name: "reports_24h" },
      { key: { Total_reports_last7_days: -1 },                   name: "reports_7d" },
      { key: { Total_reports_current_month: -1 },                name: "reports_month" },
      { key: { Average_first_time_response: 1 },                 name: "response_time" },
      { key: { scope_count: -1 },                                name: "scope_count" },
      { key: { updated_at: -1 },                                 name: "updated_at" },
      { key: { name: 1 },                                        name: "name" },
      { key: { "scope.type": 1 },                                name: "scope_type" }
    ].freeze

    def collection             = HunterMongo.collection(COLLECTION)
    def ensure_indexes_once!   = HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
    def healthy?               = HunterMongo.healthy?
  end
end
