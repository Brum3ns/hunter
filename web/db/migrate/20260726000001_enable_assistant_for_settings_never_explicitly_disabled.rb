# Any host that already rendered the settings page before this change has an
# assistant_settings row with assistant_enabled: false (the column default),
# so installing a provider key and running `docker compose up` still shows
# "Assistant disabled by an administrator" with no documented remedy.
#
# disabled_at is set exclusively by Assistant::Setting#disable!, so its
# presence is the one reliable signal that an administrator deliberately
# turned the feature off. Flip only the rows nobody ever explicitly disabled;
# a deliberate disable must survive this upgrade untouched.
class EnableAssistantForSettingsNeverExplicitlyDisabled < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE assistant_settings
      SET assistant_enabled = TRUE
      WHERE disabled_at IS NULL AND assistant_enabled = FALSE
    SQL
  end

  def down
    # Irreversible: nothing distinguishes a row this migration flipped from one
    # an administrator enabled afterward through the ordinary Settings UI path.
  end
end
