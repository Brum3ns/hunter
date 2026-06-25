namespace :users do
  desc "Reset a user's password: rails users:reset_password USERNAME=admin PASSWORD=secret"
  task reset_password: :environment do
    username = ENV["USERNAME"]
    password = ENV["PASSWORD"]
    abort("USERNAME is required") if username.blank?
    abort("PASSWORD is required") if password.blank?

    user = User.find_or_initialize_by(username: username)
    user.password = password
    user.save!
    puts "Password set for user: #{user.username}"
  end
end
