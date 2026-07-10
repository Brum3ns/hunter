# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
username = ENV.fetch("ADMIN_USERNAME", "admin")
password = ENV.fetch("ADMIN_PASSWORD", "admin")

user = User.find_or_initialize_by(username: username)
user.password = password
user.save!

puts "Seeded admin user: #{user.username}"

# Register a runner from RUNNER_TOKEN so the token can live statically in .env
# (like the admin credentials above) instead of being minted in the UI and
# copied back. The runner container reads the same RUNNER_TOKEN, so the two
# agree with no restart dance. Blank token = feature off; a weak token fails the
# seed closed so a brute-forceable identity is never created silently.
begin
  runner = Runner.ensure_from_token!(
    name: ENV.fetch("RUNNER_NAME", "default"),
    token: ENV["RUNNER_TOKEN"],
    kinds: ENV.fetch("RUNNER_KINDS", "curl").split(",").map(&:strip).reject(&:empty?)
  )

  if runner
    puts "Seeded runner: #{runner.name} (kinds: #{runner.kinds.join(', ')})"
  else
    puts "RUNNER_TOKEN not set; skipping runner bootstrap"
  end
rescue Runner::WeakTokenError => e
  abort "Runner bootstrap failed: #{e.message}. Generate one with `openssl rand -base64 32`."
end

# Programs module — seed a few sample programs into Mongo for local dev so the
# catalog page has content. No-op when the collection already has data or Mongo
# is unreachable.
begin
  if HunterMongo.healthy? && Programs::MongoSource.collection.estimated_document_count.zero?
    samples = [
      { "_sid" => "seed-h1-acme", "platform" => "hackerone", "slug" => "acme",
        "name" => "Acme", "public" => true, "bounty" => true, "bounty_min" => 100,
        "bounty_max" => 5000, "currency" => "USD", "scope_count" => 3,
        "report_count" => 42, "collaboration" => true, "updated_at" => Time.current,
        "scope" => [{ "asset" => "*.acme.com", "type" => "WILDCARD" }] },
      { "_sid" => "seed-bc-globex", "platform" => "bugcrowd", "slug" => "globex",
        "name" => "Globex", "public" => true, "bounty" => true, "bounty_max" => 10000,
        "currency" => "USD", "scope_count" => 1, "report_count" => 8,
        "updated_at" => Time.current,
        "scope" => [{ "asset" => "api.globex.com", "type" => "API" }] }
    ]
    samples.each do |doc|
      Programs::MongoSource.collection.update_one({ _sid: doc["_sid"] }, { "$set" => doc }, upsert: true)
    end
    puts "Seeded #{samples.size} sample programs into Mongo."
  end
rescue Mongo::Error => e
  warn "Skipped program seeds (mongo: #{e.message})"
end
