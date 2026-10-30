class UserOshisController < ApplicationController
  include OshiCandidateAssets
  before_action :set_user_oshi, only: [ :show, :edit, :update ]
  prepend_before_action :authenticate_activity_panel_user!, only: [ :index, :create ]
  before_action :verify_activity_panel_context, only: [ :index, :create ]

  def index
    @user_oshis = current_user.user_oshis.includes(:oshi, representative_image_attachment: :blob).order(:id)
    render json: { oshis: @user_oshis.map { |record| panel_registration_payload(record, result: "owned") } } if activity_panel_request?
  end

  def show
  end

  def edit
  end

  def create
    return if reject_panel_images

    oshi = Oshi.visible_to(current_user).find(params.require(:oshi_id))
    @existing_user_oshi = current_user.user_oshis.new(started_period_params.merge(oshi: oshi))

    UserOshis::Save.call(user_oshi: @existing_user_oshi, new_images: image_upload_params)
    if activity_panel_request?
      render json: panel_registration_payload(@existing_user_oshi), status: :created
    else
      redirect_to post_oshi_registration_path(@existing_user_oshi), notice: t("notices.oshis.created"), status: :see_other
    end
  rescue ActiveRecord::RecordInvalid
    if @existing_user_oshi.errors.of_kind?(:oshi_id, :taken)
      redirect_duplicate
    else
      if activity_panel_request?
        return render json: { error: "validation", errors: @existing_user_oshi.errors.full_messages }, status: :unprocessable_content
      end
      @oshi = Oshi.new
      @user_oshi = current_user.user_oshis.new
      @oshis = Oshi.visible_to(current_user).search(params[:q]).order(:name, :id)
        .limit(OshisController::SEARCH_LIMIT).to_a
      # Keep the selected, still-visible candidate available after a failed POST.
      @oshis = Oshi.visible_to(current_user).where(id: oshi.id)
        .to_a if @oshis.empty?
      load_oshi_candidate_assets
      render "oshis/new", status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_duplicate
  rescue ActiveRecord::RecordNotFound => error
    if activity_panel_request?
      render json: { error: "unavailable", message: t("ui.activity_panel.unavailable") }, status: :not_found
    else
      render_user_data_not_found(error)
    end
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
      if activity_panel_request?
        existing = current_user.user_oshis.find_by!(oshi_id: @existing_user_oshi.oshi_id)
        return render json: panel_registration_payload(existing, result: "already_registered")
      end
      redirect_to oshis_path, alert: t("alerts.oshis.already_registered"), status: :see_other
    end
end
