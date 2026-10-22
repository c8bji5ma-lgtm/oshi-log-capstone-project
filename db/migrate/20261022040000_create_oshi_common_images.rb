class CreateOshiCommonImages < ActiveRecord::Migration[8.1]
  def change
    create_table :oshi_common_images do |t|
      t.references :oshi, null: false, foreign_key: true
      t.references :registered_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :source_url, limit: 2048, null: false
      t.string :creator_name, limit: 255, null: false
      t.string :license_name, limit: 255, null: false
      t.text :attribution_text, null: false
      t.text :usage_notes
      t.datetime :rights_confirmed_at, null: false
      t.boolean :active, null: false, default: true
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :oshi_common_images, [ :oshi_id, :active ]
    add_index :oshi_common_images, :source_url
  end
end
