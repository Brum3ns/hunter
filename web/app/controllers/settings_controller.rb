class SettingsController < ApplicationController
  def show
    @runners = Runner.order(:name)
  end
end
