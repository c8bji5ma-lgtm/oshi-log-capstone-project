class OshiCommonImage < ApplicationRecord
  LIMIT_PER_OSHI = 10

  belongs_to :oshi
  belongs_to :registered_by_user, class_name: "User", optional: true
  has_one_attached :image

  validates :source_url, presence: true, length: { maximum: 2048 },
    format: { with: %r{\Ahttps?://[^\s]+\z}, message: "はhttpまたはhttpsのURLを入力してください" }
  validates :creator_name, :license_name, presence: true, length: { maximum: 255 }
  validates :attribution_text, :rights_confirmed_at, presence: true
  validates :active, inclusion: { in: [ true, false ] }
  validates :image, image_attachment: true
  validate :image_is_attached

  scope :active, -> { where(active: true) }

  private

    def image_is_attached
      errors.add(:image, "を選択してください") unless image.attached?
    end
end
