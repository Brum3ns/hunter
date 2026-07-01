class CreateRunners < ActiveRecord::Migration[8.1]
  def change
    create_table :runners do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :kinds, array: true, null: false, default: []
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :runners, :name, unique: true
    add_index :runners, :token_digest, unique: true
  end
end
