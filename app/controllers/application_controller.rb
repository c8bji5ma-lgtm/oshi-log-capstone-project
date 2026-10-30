class ApplicationController < ActionController::Base
  FIRST_ACTIVITY_CONTINUATION = "first_activity".freeze

  before_action :authenticate_user!, unless: :devise_controller?
  before_action :block_registration_in_demo_sandbox
  before_action :enforce_read_only_guest_session
  helper_method :first_activity_continuation?, :activity_context_token, :activity_panel_writable?

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  protected

  def block_registration_in_demo_sandbox
    return unless GraduationGuestSandbox.enabled? && controller_path == "devise/registrations"

    render plain: "デモ環境では新しいアカウントを登録できません。", status: :forbidden
  end

  def enforce_read_only_guest_session
    role = session[:graduation_guest_role]
    reserved_session = GraduationGuestSandbox.enabled? &&
      GraduationGuestSandbox.reserved_email?(current_user&.email)
    return if role.blank? && !reserved_session

    unless GraduationGuestSandbox.ready? && GraduationGuestSandbox.actor?(current_user, role)
      sign_out(:user)
      session.delete(:graduation_guest_role)
      return redirect_to(root_path, alert: "ゲスト利用を終了しました。", status: :see_other)
    end

    return if request.get? || request.head?
    return if devise_controller? && controller_name == "sessions" && action_name == "destroy"

    if html_navigation_request?
      render "errors/guest_read_only", formats: [ :html ], status: :forbidden
    else
      render plain: "ゲストは閲覧専用です。登録・変更・削除はできません。", status: :forbidden
    end
  end

  def activity_context_token
    @activity_context_token ||= Rails.application.message_verifier("activity_input").generate(
      { "user_id" => current_user.id, "nonce" => request.env.fetch("warden").session(:user)["activity_input_nonce"] ||= SecureRandom.hex(32) },
      purpose: "activity_input", expires_in: 2.hours
    )
  end

  def activity_panel_writable?
    session[:graduation_guest_role].blank?
  end

  def activity_panel_request?
    params[:activity_panel] == "1" || request.headers["X-Activity-Panel"] == "1" || request.format.json?
  end

  def authenticate_activity_panel_user!
    return unless activity_panel_request?
    return if user_signed_in?

    response.headers["Cache-Control"] = "no-store"
    render json: { error: "context", message: t("ui.activity_panel.context_error") }, status: :unauthorized
  end

  def verify_activity_panel_context
    return unless activity_panel_request?

    response.headers["Cache-Control"] = "no-store"

    unless activity_panel_writable?
      return render json: { error: "read_only", message: t("ui.activity_panel.read_only") }, status: :forbidden
    end
    require_activity_context!(params[:activity_context_token] || request.headers["X-Activity-Context-Token"])
  end

  def require_activity_context!(token)
    data = if token.is_a?(String) && token.bytesize <= 4096
      Rails.application.message_verifier("activity_input").verified(token, purpose: "activity_input")
    end
    nonce = request.env.fetch("warden").session(:user)["activity_input_nonce"]
    valid = data.is_a?(Hash) && data["user_id"] == current_user.id && nonce.is_a?(String) &&
      data["nonce"].is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(data["nonce"], nonce)
    if valid
      @activity_context_token = token
      return true
    end

    response.headers["Cache-Control"] = "no-store"
    if request.format.json? || activity_panel_request?
      render json: { error: "context", message: t("ui.activity_panel.context_error") }, status: :conflict
    else
      render "activities/context_error", formats: [ :html ], status: :conflict
    end
    false
  end

  def panel_registration_payload(user_oshi, result: "registered")
    oshi = user_oshi.oshi
    { result: result, oshi: { id: oshi.id, name: oshi.name, oshi_type: oshi.oshi_type, affiliation: oshi.affiliation,
      status: oshi.status }, started_period: user_oshi.started_period, ended_period: user_oshi.ended_period }
  end

  def reject_panel_images
    return false unless activity_panel_request?

    images = params[:user_oshi].is_a?(ActionController::Parameters) ? params[:user_oshi][:library_images] : nil
    return false if images.nil? || images == "" || images == []

    render json: { error: "validation", errors: [ t("ui.activity_panel.photos_later") ] }, status: :unprocessable_content
    true
  end

  def first_activity_continuation?
    params[:continue] == FIRST_ACTIVITY_CONTINUATION
  end

  def post_oshi_registration_path(user_oshi)
    return oshis_path unless first_activity_continuation?

    new_activity_path(initial_oshi_id: user_oshi.oshi_id)
  end

  def html_navigation_request?
    request.format.html? || request.format.turbo_stream?
  end

  def render_user_data_not_found(error)
    raise error unless html_navigation_request?

    render "errors/not_found", formats: [ :html ], status: :not_found
  end

  def after_sign_out_path_for(_resource_or_scope)
    new_user_session_path
  end
end
