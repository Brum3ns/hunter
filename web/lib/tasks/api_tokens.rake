namespace :api_tokens do
  desc "Create an API token: rails api_tokens:create USERNAME=admin NAME=ci"
  task create: :environment do
    username = ENV["USERNAME"]
    name = ENV["NAME"].presence || "default"
    abort("USERNAME is required") if username.blank?

    user = User.find_by(username: username.strip.downcase)
    abort("No user found for username: #{username}") if user.nil?

    record, raw = ApiToken.generate(user: user, name: name)
    puts "API token created for #{user.username} (#{record.name}):"
    puts
    puts "  #{raw}"
    puts
    puts "Store it now — only its digest is saved, so it cannot be shown again."
  end
end
