class AddLockVersionsToActivitiesAndSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :activities, :lock_version, :integer, null: false, default: 0
    add_column :subscriptions, :lock_version, :integer, null: false, default: 0
  end
end
