Rails.application.config.after_initialize do
  state = Assistant::Activation.state
  Rails.logger.info(
    "[assistant] active=#{state.active} reason=#{state.reason} providers=#{state.available_slugs.join(',')}"
  )
end
