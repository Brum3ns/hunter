class SettingsController < ApplicationController
  def show
    @runners = Runner.order(:name)
    @ansible_credentials = ControlCenter::Ansible::Credential.order(:name)
    @schedule = Current.user.scope_schedule || Current.user.build_scope_schedule
    @monitor_config = Current.user.monitor_config || Current.user.build_monitor_config
    @assistant_admin = Assistant::AdminPolicy.allowed?(Current.user)
    if @assistant_admin
      @assistant_setting = Assistant::Setting.instance
      @assistant_profiles = Assistant::ProviderProfile.order(:name)
      @assistant_catalog_entries = Assistant::ProviderCatalog.entries.values
    end
  end
end
