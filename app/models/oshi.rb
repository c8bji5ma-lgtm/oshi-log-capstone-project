class Oshi < ApplicationRecord
  OSHI_TYPES = [
    "アイドル", "アーティスト", "俳優・タレント", "声優",
    "キャラクター", "スポーツ", "その他"
  ].freeze

  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :oshi_aliases
  has_many :oshi_common_images
  has_many :user_oshis
  has_many :users, through: :user_oshis
  has_many :activity_oshis
  has_many :activities, through: :activity_oshis
  has_many :subscription_oshis
  has_many :subscriptions, through: :subscription_oshis

  enum :status, {
    pending: "pending", approved: "approved", rejected: "rejected"
  }, validate: true

  scope :visible_to, ->(user) { approved.or(pending.where(created_by_user_id: user.id)) }

  def self.search(query)
    return none if query.blank?

    pattern = "%#{sanitize_sql_like(query)}%"
    left_outer_joins(:oshi_aliases)
      .where("oshis.name ILIKE :pattern OR oshi_aliases.alias_name ILIKE :pattern", pattern: pattern)
      .distinct
  end

  validates :name, presence: true, length: { maximum: 255 }
  validates :oshi_type, presence: true, length: { maximum: 50 },
    inclusion: { in: OSHI_TYPES }
  validates :affiliation, length: { maximum: 255 }
end
