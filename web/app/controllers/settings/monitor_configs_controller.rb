module Settings
  # Saves the current user's MongoDB monitor settings (Settings → Monitor).
  class MonitorConfigsController < ApplicationController
    def update
      config = Current.user.monitor_config || Current.user.build_monitor_config
      config.assign_attributes(config_params)
      config.recompute_next_tick_at!

      if config.save
        redirect_to settings_path(anchor: "monitor"), notice: "Monitor settings saved."
      else
        redirect_to settings_path(anchor: "monitor"), alert: config.errors.full_messages.to_sentence
      end
    end

    private

    def config_params
      permitted = params.require(:monitor_config).permit(:enabled, :interval_seconds, platforms: [])
      permitted[:platforms] = Array(permitted[:platforms]).reject(&:blank?)
      permitted
    end
  end
end
