class OshisController < ApplicationController
  SEARCH_LIMIT = 50
  def new
    @oshi = Oshi.new
    @user_oshi = current_user.user_oshis.new
    @existing_user_oshi = current_user.user_oshis.new
    load_search_candidates
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
    load_search_candidates
    render :new, status: :unprocessable_content
  end

  private

    def load_search_candidates
      candidates = Oshi.visible_to(current_user).search(params[:q]).order(:name, :id).limit(SEARCH_LIMIT + 1).to_a
      @oshi_search_has_more = candidates.size > SEARCH_LIMIT
      @oshis = candidates.first(SEARCH_LIMIT)
    end

    def oshi_params
      params.require(:oshi).permit(:name, :oshi_type, :affiliation)
    end

    def started_period_params
      params.fetch(:user_oshi, ActionController::Parameters.new).permit(:started_period)
    end
end
