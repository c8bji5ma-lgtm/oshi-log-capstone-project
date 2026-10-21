class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: :index

  def index
    if user_signed_in?
      prepare_home
      render :home
    else
      render :top
    end
  end

  def home
    prepare_home
  end

  def my_page
  end

  private

    def prepare_home
      reference_date = Date.current
      month_activities = current_user.activities.where(occurred_on: reference_date.beginning_of_month..reference_date)

      @home_summary = OshiData::Summary.new(user: current_user, date: reference_date)
      @month_activity_count = month_activities.count
      @month_activity_amount = month_activities.sum(:amount)
      @month_amount_recorded = month_activities.where.not(amount: nil).exists?
      @home_user_oshis = current_user.user_oshis.preload(:oshi, representative_image_attachment: :blob).to_a
        .sort_by { |record| [ record.oshi.name, record.oshi_id ] }
      @recent_activities = current_user.activities
        .where("occurred_on <= ?", reference_date)
        .includes(:oshis, :emotions, images_attachments: :blob)
        .order(occurred_on: :desc, created_at: :desc, id: :desc)
        .limit(3)
    end
end
