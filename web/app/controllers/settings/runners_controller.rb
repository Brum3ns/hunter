module Settings
  # Mint and revoke runner identities from the Settings page. Minting reuses
  # Runner.generate (random token, digest stored, raw returned once); the raw
  # token rides in the flash so it is shown exactly once. Revoke is a permanent
  # delete — dependent: :nullify unlinks past jobs so their history survives.
  class RunnersController < ApplicationController
    def create
      kinds = Array(params[:kinds]).map { |k| k.to_s.strip }.reject(&:blank?)
      runner, raw = Runner.generate(name: params[:name].to_s.strip, kinds: kinds)
      flash[:runner_token] = raw
      flash[:runner_name] = runner.name
      redirect_to settings_path, notice: "Runner “#{runner.name}” created."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      Runner.find(params[:id]).destroy
      redirect_to settings_path, notice: "Runner revoked."
    end
  end
end
