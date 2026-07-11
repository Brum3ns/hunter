class CreateControlCenterTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_templates do |t|
      t.string  :name, null: false
      t.string  :kind, null: false, default: "cmdscript"
      t.jsonb   :tags, null: false, default: []
      t.text    :description, null: false, default: ""
      t.string  :output
      t.jsonb   :commands, null: false, default: []
      t.jsonb   :target
      t.string  :created_by
      t.timestamps
    end
    add_index :control_center_templates, :name, unique: true
  end
end
