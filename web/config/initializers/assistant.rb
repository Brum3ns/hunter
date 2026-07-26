Rails.application.config.after_initialize do
  Assistant::Config.validate_production! if Rails.env.production?
end
