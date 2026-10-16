class UserOshiImagesController < ApplicationController
  before_action :set_user_oshi
  rescue_from ActiveRecord::RecordNotFound, with: :render_user_data_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_image_errors

  def create
    UserOshis::Save.call(user_oshi: @user_oshi,
      new_images: params.fetch(:user_oshi, ActionController::Parameters.new)[:library_images])
    redirect_to edit_user_oshi_path(@user_oshi), notice: "画像を追加しました。", status: :see_other
  end

  def update
    UserOshis::Save.call(user_oshi: @user_oshi, representative_image_id: params[:id])
    redirect_to edit_user_oshi_path(@user_oshi), notice: "代表画像を変更しました。", status: :see_other
  end

  def destroy
    UserOshis::Save.call(user_oshi: @user_oshi, remove_image_id: params[:id],
      clear_representative: params[:clear_representative] == "1")
    redirect_to edit_user_oshi_path(@user_oshi), notice: "画像を削除しました。", status: :see_other
  end

  private

    def set_user_oshi
      @user_oshi = current_user.user_oshis.find(params[:user_oshi_id])
    end

    def render_image_errors(_error)
      saved = current_user.user_oshis.includes(:oshi, representative_image_attachment: :blob, library_images_attachments: :blob).find(@user_oshi.id)
      @representative_image = saved.representative_image.attachment
      @images = saved.image_library
      render "user_oshis/edit", status: :unprocessable_content
    end
end
