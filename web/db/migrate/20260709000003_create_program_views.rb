class CreateProgramViews < ActiveRecord::Migration[8.1]
  def change
    create_table :program_views do |t|
      t.references :user, null: false, foreign_key: true
      t.string :program_sid, null: false
      t.datetime :viewed_at, null: false
      t.timestamps
    end
    add_index :program_views, [:user_id, :program_sid], unique: true
    add_index :program_views, [:user_id, :viewed_at]
  end
end
