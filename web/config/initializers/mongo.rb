require "mongo"

Mongo::Logger.logger.level = Logger::WARN

# Connection + collection handles for MongoDB. Hunter is multi-module: each
# module (Programs, Vulnerability management, CVE tracking, ...) reads/writes its
# own collection, so the wiring is collection-agnostic — callers name the
# collection and supply its index spec. Mirrors scope-ui's ScopeMongo (single
# memoized client, env-driven addresses) but generalized beyond one collection.
module HunterMongo
  module_function

  def client
    @client ||= Mongo::Client.new(addresses, client_options.merge(database: database))
  end

  # Handle for a named collection. Modules pass their own collection name.
  def collection(name)
    client[name.to_s]
  end

  # Creates the given indexes on a collection at most once per process.
  # createIndexes is idempotent server-side; the mutex just spares the extra
  # round-trip on hot paths. Each module calls this with its own collection +
  # INDEXES before its first query.
  def ensure_indexes_once!(name, indexes)
    key = name.to_s
    @indexes_ready ||= {}
    return true if @indexes_ready[key]

    (@indexes_mutex ||= Mutex.new).synchronize do
      return true if @indexes_ready[key]
      @indexes_ready[key] = ensure_indexes!(key, indexes)
    end
  end

  def ensure_indexes!(name, indexes)
    return true if indexes.blank?
    collection(name).indexes.create_many(indexes)
    true
  rescue Mongo::Error => e
    Rails.logger.warn("mongo: ensure_indexes failed for #{name} (#{e.message})")
    false
  end

  def database
    ENV.fetch("MONGO_DATABASE", "bugbounty")
  end

  def healthy?
    client.command(ping: 1)
    true
  rescue Mongo::Error => e
    Rails.logger.warn("mongo: unreachable (#{e.class}: #{e.message})")
    false
  end

  def reset!
    @client&.close
    @client = nil
    @indexes_ready = {}
  end

  def addresses
    [ENV.fetch("MONGO_HOST", "localhost") + ":" + ENV.fetch("MONGO_PORT", "27017")]
  end

  def client_options
    opts = {
      server_selection_timeout: Integer(ENV.fetch("MONGO_SERVER_SELECTION_TIMEOUT", "3")),
      connect_timeout: Integer(ENV.fetch("MONGO_CONNECT_TIMEOUT", "3"))
    }
    # Naming the replica set puts the driver in replica-set topology (not a
    # direct connection), which change streams require. Left unset for a
    # standalone Mongo, where passing it would prevent connecting.
    replica_set = ENV["MONGO_REPLICA_SET"].presence
    opts[:replica_set] = replica_set if replica_set
    user = ENV["MONGO_USERNAME"].presence
    pass = ENV["MONGO_PASSWORD"].presence
    opts.merge!(user: user, password: pass, auth_source: ENV.fetch("MONGO_AUTH_SOURCE", "admin")) if user && pass
    opts
  end
end
