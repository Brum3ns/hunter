class ExpandAssistantOperationalLimits < ActiveRecord::Migration[8.0]
  def up
    change_column_default :assistant_provider_profiles, :tool_call_limit, from: 8, to: 64
    remove_check_constraint :assistant_provider_profiles,
      name: "assistant_profiles_tool_call_limit_bounded"
    add_check_constraint :assistant_provider_profiles,
      "tool_call_limit >= 1 AND tool_call_limit <= 128",
      name: "assistant_profiles_tool_call_limit_bounded"

    execute <<~SQL.squish
      UPDATE assistant_provider_profiles
      SET tool_call_limit = 64
      WHERE tool_call_limit = 8
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE assistant_provider_profiles
      SET tool_call_limit = 8
      WHERE tool_call_limit > 8
    SQL

    remove_check_constraint :assistant_provider_profiles,
      name: "assistant_profiles_tool_call_limit_bounded"
    add_check_constraint :assistant_provider_profiles,
      "tool_call_limit >= 1 AND tool_call_limit <= 8",
      name: "assistant_profiles_tool_call_limit_bounded"
    change_column_default :assistant_provider_profiles, :tool_call_limit, from: 64, to: 8
  end
end
