namespace :api_tokens do
  desc "Create an API token: rails api_tokens:create USERNAME=admin NAME=ci SCOPES=cves,programs"
  task create: :environment do
    username = ENV["USERNAME"]
    name = ENV["NAME"].presence || "default"
    abort("USERNAME is required") if username.blank?

    scopes = ENV["SCOPES"].to_s.split(",").map(&:strip).reject(&:empty?)
    scopes = [ApiToken::WILDCARD] if scopes.empty?
    unknown = scopes - (ApiToken::MODULE_SCOPES + [ApiToken::WILDCARD])
    abort("Unknown scope(s): #{unknown.join(', ')}") if unknown.any?

    user = User.find_by(username: username.strip.downcase)
    abort("No user found for username: #{username}") if user.nil?

    record, raw = ApiToken.generate(user: user, name: name, scopes: scopes)
    puts "API token created for #{user.username} (#{record.name}) scopes=#{record.scopes.join(',')}:"
    puts
    puts "  #{raw}"
    puts
    puts "Store it now — only its digest is saved, so it cannot be shown again."
  end

  desc "Set a CVE saved filter: rails api_tokens:set_cve_filter USERNAME=admin NAME=llm FILTER='{...}'"
  task set_cve_filter: :environment do
    username = ENV["USERNAME"]
    name = ENV["NAME"]
    abort("USERNAME is required") if username.blank?
    abort("NAME is required") if name.blank?

    begin
      filter = JSON.parse(ENV["FILTER"].to_s)
    rescue JSON::ParserError => e
      abort("FILTER is not valid JSON: #{e.message}")
    end
    abort("FILTER must be a JSON object") unless filter.is_a?(Hash)

    user = User.find_by(username: username.strip.downcase)
    abort("No user found for username: #{username}") if user.nil?
    token = user.api_tokens.find_by(name: name)
    abort("No token named #{name} for #{user.username}") if token.nil?

    token.update!(cve_filter: filter)
    puts "Saved CVE filter on #{user.username}/#{token.name}: #{token.cve_filter.inspect}"
  end
end
