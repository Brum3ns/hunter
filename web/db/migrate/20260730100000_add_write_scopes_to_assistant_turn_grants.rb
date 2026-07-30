class AddWriteScopesToAssistantTurnGrants < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_turn_grants, :write_scopes, :jsonb, default: [], null: false
  end
end
