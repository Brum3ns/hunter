class SettingsController < ApplicationController
  def show
    @runners = Runner.order(:name)
    @schedule = Current.user.scope_schedule || Current.user.build_scope_schedule
    @monitor_config = Current.user.monitor_config || Current.user.build_monitor_config
  end
end
