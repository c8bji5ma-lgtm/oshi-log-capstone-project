class UserOshi < ApplicationRecord
  PERIOD_FORMAT = /\A[0-9]{4}(?:\/(?:0[1-9]|1[0-2]))?\z/
  IMAGE_LIMIT = 30

  belongs_to :user
  belongs_to :oshi

  before_validation :normalize_empty_periods

  has_one_attached :representative_image
  has_many_attached :library_images
  validates :representative_image, image_attachment: true
  validates :library_images, image_attachment: true
  validate :image_library_within_limit

  validates :oshi_id, uniqueness: { scope: :user_id }
  validates :started_period, :ended_period,
    format: { with: PERIOD_FORMAT }, allow_nil: true

  # Prefer library attachment IDs, including when the same blob is representative.
  # Blob creation order stays stable across representative changes.
  def image_library
    (library_images.attachments.to_a + [ representative_image.attachment ].compact)
      .uniq { |image| image.blob.id || image.blob.object_id }
      .sort_by { |image| [ image.blob.created_at || Time.current, image.blob.id || 0 ] }
  end

  def image_count
    image_library.size
  end

  def remaining_image_count
    IMAGE_LIMIT - image_count
  end

  private

    def image_library_within_limit
      errors.add(:library_images, "は代表画像を含めて最大#{IMAGE_LIMIT}枚です") if image_count > IMAGE_LIMIT
    end

    def normalize_empty_periods
      self.started_period = nil if started_period == ""
      self.ended_period = nil if ended_period == ""
    end
end
