class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable

  has_one :profile
  has_many :user_oshis
  has_many :oshis, through: :user_oshis
  has_many :created_oshis, class_name: "Oshi", foreign_key: :created_by_user_id
  has_many :registered_oshi_common_images, class_name: "OshiCommonImage", foreign_key: :registered_by_user_id
  has_many :activities
  has_many :subscriptions

  validates :admin, inclusion: { in: [ true, false ] }
end
