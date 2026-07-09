class CreateTrashes < ActiveRecord::Migration[8.1]
  def change
    create_table :trashes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :program_sid, null: false
      t.timestamps
    end
    add_index :trashes, [:user_id, :program_sid], unique: true
  end
end
