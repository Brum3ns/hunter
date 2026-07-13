class AddScopesAndCveFilterToApiTokens < ActiveRecord::Migration[8.0]
  def change
    add_column :api_tokens, :scopes, :string, array: true, null: false, default: ["*"]
    add_column :api_tokens, :cve_filter, :jsonb, null: false, default: {}
  end
end
