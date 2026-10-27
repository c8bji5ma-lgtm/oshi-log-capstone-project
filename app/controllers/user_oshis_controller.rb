class UserOshisController < ApplicationController
  before_action :set_user_oshi, only: [ :show, :edit, :update ]

  def index
    @user_oshis = current_user.user_oshis.includes(:oshi, representative_image_attachment: :blob).order(:id)
  end

  def show
  end

  def edit
  end

  def create
    oshi = Oshi.visible_to(current_user).find(params.require(:oshi_id))
    @existing_user_oshi = current_user.user_oshis.new(started_period_params.merge(oshi: oshi))

    UserOshis::Save.call(user_oshi: @existing_user_oshi, new_images: image_upload_params)
    redirect_to post_oshi_registration_path(@existing_user_oshi), notice: t("notices.oshis.created"), status: :see_other
  rescue ActiveRecord::RecordInvalid
    if @existing_user_oshi.errors.of_kind?(:oshi_id, :taken)
      redirect_duplicate
    else
      @oshi = Oshi.new
      @user_oshi = current_user.user_oshis.new
      @oshis = Oshi.visible_to(current_user).search(params[:q]).order(:name, :id)
        .includes(oshi_common_images: { image_attachment: :blob }).limit(OshisController::SEARCH_LIMIT).to_a
      # Keep the selected, still-visible candidate available after a failed POST.
      @oshis = Oshi.visible_to(current_user).where(id: oshi.id)
        .includes(oshi_common_images: { image_attachment: :blob }).to_a if @oshis.empty?
      @common_images = @oshis.to_h do |candidate|
        [ candidate.id, candidate.oshi_common_images.select(&:active?).select { |item| item.image.attached? }.sample ]
      end
      render "oshis/new", status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_duplicate
  rescue ActiveRecord::RecordNotFound => error
    render_user_data_not_found(error)
  end

  def update
    UserOshis::Save.call(user_oshi: @user_oshi, attributes: user_oshi_params, new_images: image_upload_params)
    redirect_to oshis_path, notice: t("notices.oshis.updated"), status: :see_other
  rescue ActiveRecord::RecordInvalid
    load_saved_images
    render :edit, status: :unprocessable_content
  end

  private

    def set_user_oshi
      @user_oshi = current_user.user_oshis.includes(:oshi, representative_image_attachment: :blob, library_images_attachments: :blob).find(params[:id])
      load_saved_images(@user_oshi)
    rescue ActiveRecord::RecordNotFound => error
      render_user_data_not_found(error)
    end

    def started_period_params
      params.fetch(:user_oshi, ActionController::Parameters.new).permit(:started_period)
    end

    def user_oshi_params
      input = params.require(:user_oshi)
      attributes = input.permit(:started_period, :ended_period).to_h
      attributes[:representative_image] = input[:representative_image] if input.key?(:representative_image)
      attributes
    end

    def image_upload_params
      params.fetch(:user_oshi, ActionController::Parameters.new)[:library_images]
    end

    def load_saved_images(saved = nil)
      saved ||= current_user.user_oshis.includes(representative_image_attachment: :blob, library_images_attachments: :blob).find(@user_oshi.id)
      @representative_image = saved.representative_image.attachment
      @images = saved.image_library
    end

    def redirect_duplicate
      redirect_to oshis_path, alert: t("alerts.oshis.already_registered"), status: :see_other
    end
end
