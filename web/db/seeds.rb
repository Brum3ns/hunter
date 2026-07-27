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

# Assistant machine identity. hunter-mcp authenticates to the Rails machine API
# with ASSISTANT_MCP_HUNTER_TOKEN; Postgres stores only its digest. Installing it
# here — rather than from a bootstrap one-shot writing a shared volume — is what
# makes `docker compose up` bring the Assistant up ready to go.
raw_mcp_token = ENV["ASSISTANT_MCP_HUNTER_TOKEN"].to_s
if raw_mcp_token.strip.empty?
  puts "[assistant] ASSISTANT_MCP_HUNTER_TOKEN unset; hunter-mcp identity not installed."
elsif raw_mcp_token.strip.length < Assistant::ServiceIdentity::MIN_TOKEN_LENGTH
  # Fail loudly rather than installing a weak machine credential, matching how a
  # weak RUNNER_TOKEN aborts the seed.
  abort "[assistant] ASSISTANT_MCP_HUNTER_TOKEN must be at least " \
        "#{Assistant::ServiceIdentity::MIN_TOKEN_LENGTH} characters; generate one with `openssl rand -base64 32`."
else
  identity = Assistant::ServiceIdentity.install_from_environment!(raw_mcp_token)
  puts "[assistant] Installed hunter-mcp service identity ##{identity.id}."
end

# A provider profile per resolvable provider key. Activation derives from the keys
# alone, but the chat binds a conversation to a profile ROW, so without this a
# fresh database reports the Assistant active while every conversation fails to
# start. Existing profiles are never modified: an administrator who disabled one
# must not have it re-enabled by the next boot.
profiles = Assistant::ProviderProfileInstaller.call(created_by: user)
if profiles.installed.any?
  puts "[assistant] Installed provider profiles: #{profiles.installed.join(', ')}."
end
if profiles.untouched.any?
  puts "[assistant] Left existing provider profiles untouched: #{profiles.untouched.join(', ')}."
end
if profiles.skipped.any?
  puts "[assistant] No usable credential for: #{profiles.skipped.join(', ')} (no profile created)."
end
if profiles.failed.any?
  # Reported, never raised: the seed must not stop `foreman start` from running.
  warn "[assistant] Could not install provider profiles: #{profiles.failed.join(', ')}. " \
       "A conflicting profile name probably already exists; fix it in Settings."
end
if profiles.installed.empty? && profiles.untouched.empty?
  puts "[assistant] No provider profile exists; set ASSISTANT_ANTHROPIC_API_KEY or " \
       "ASSISTANT_OPENAI_API_KEY and re-run db:seed to enable the chat."
end
