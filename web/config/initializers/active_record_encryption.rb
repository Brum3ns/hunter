Rails.application.config.after_initialize do
  next unless Rails.env.production?

  config = ActiveRecord::Encryption.config
  missing = %i[primary_key deterministic_key key_derivation_salt].select do |name|
    !config.public_send("has_#{name}?")
  end
  next if missing.empty?

  names = missing.map { |name| "ACTIVE_RECORD_ENCRYPTION_#{name.to_s.upcase}" }
  raise "Missing Active Record encryption secrets: #{names.join(', ')}"
end
