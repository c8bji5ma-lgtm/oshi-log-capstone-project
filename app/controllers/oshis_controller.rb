class OshisController < ApplicationController
  def new
    @oshi = Oshi.new
    @user_oshi = current_user.user_oshis.new
    @existing_user_oshi = current_user.user_oshis.new
    @oshis = Oshi.visible_to(current_user).search(params[:q]).order(:name, :id)
  end

  def create
    @oshi = Oshi.new(oshi_params)
    @oshi.status = :pending
    @oshi.created_by_user = current_user
    @user_oshi = current_user.user_oshis.new(started_period_params.merge(oshi: @oshi))

    UserOshis::Save.call(user_oshi: @user_oshi,
      new_images: params.fetch(:user_oshi, ActionController::Parameters.new)[:library_images])

    redirect_to oshis_path, notice: "推しを登録しました。", status: :see_other
  rescue ActiveRecord::RecordInvalid
    @oshi.valid?
    @user_oshi.valid? if @user_oshi.errors.empty?
    @existing_user_oshi = current_user.user_oshis.new
    @oshis = Oshi.visible_to(current_user).search(params[:q]).order(:name, :id)
    render :new, status: :unprocessable_content
  end

  private

    def oshi_params
      params.require(:oshi).permit(:name, :oshi_type, :affiliation)
    end

    def started_period_params
      params.fetch(:user_oshi, ActionController::Parameters.new).permit(:started_period)
    end
end
