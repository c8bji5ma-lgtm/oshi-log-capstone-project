class OshisController < ApplicationController
  include OshiCandidateAssets
  SEARCH_LIMIT = 50
  SUGGESTION_LIMIT = 8
  prepend_before_action :authenticate_activity_panel_user!, only: [ :new, :create ]
  before_action :verify_activity_panel_context, only: [ :new, :create ]
  def new
    @oshi = Oshi.new
    @user_oshi = current_user.user_oshis.new
    @existing_user_oshi = current_user.user_oshis.new
    load_search_candidates
    if params[:suggest] == "1"
      response.headers["Cache-Control"] = "private, no-store"
      return render partial: "oshis/suggestions"
    end
    render partial: "oshis/registration", locals: { inline: true, context_token: @activity_context_token } if activity_panel_request?
  end

  def create
    return if reject_panel_images

    @oshi = Oshi.new(oshi_params)
    @oshi.status = :pending
    @oshi.created_by_user = current_user
    @user_oshi = current_user.user_oshis.new(started_period_params.merge(oshi: @oshi))

    UserOshis::Save.call(user_oshi: @user_oshi,
      new_images: params.fetch(:user_oshi, ActionController::Parameters.new)[:library_images])

    if activity_panel_request?
      render json: panel_registration_payload(@user_oshi), status: :created
    else
      redirect_to post_oshi_registration_path(@user_oshi), notice: t("notices.oshis.created"), status: :see_other
    end
  rescue ActiveRecord::RecordInvalid
    @oshi.valid?
    @user_oshi.valid? if @user_oshi.errors.empty?
    if activity_panel_request?
      return render json: { error: "validation", errors: @oshi.errors.full_messages + @user_oshi.errors.full_messages }, status: :unprocessable_content
    end
    @existing_user_oshi = current_user.user_oshis.new
    load_search_candidates
    render :new, status: :unprocessable_content
  end

  private

    def load_search_candidates
      query = params[:q].is_a?(String) ? params[:q] : ""
      limit = params[:suggest] == "1" ? SUGGESTION_LIMIT : SEARCH_LIMIT
      candidates = Oshi.visible_to(current_user).search(query).order(:name, :id).limit(limit + 1).to_a
      @oshi_search_has_more = candidates.size > limit
      @oshis = candidates.first(limit)
      load_oshi_candidate_assets
      @oshis = @catalog_oshis if query.blank? && params[:suggest] != "1"
    end

    def oshi_params
      params.require(:oshi).permit(:name, :oshi_type, :affiliation)
    end

    def started_period_params
      params.fetch(:user_oshi, ActionController::Parameters.new).permit(:started_period)
    end
end
