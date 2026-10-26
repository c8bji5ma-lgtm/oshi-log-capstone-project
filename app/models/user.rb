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

  # The published development-seed passwords must never authenticate the
  # reserved demo actors through the regular sign-in form in sandbox mode.
  def valid_for_authentication?
    return false if GraduationGuestSandbox.enabled? && GraduationGuestSandbox.reserved_email?(email)

    super
  end
end
