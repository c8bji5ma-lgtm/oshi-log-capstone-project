class ApplicationController < ActionController::Base
  FIRST_ACTIVITY_CONTINUATION = "first_activity".freeze

  before_action :authenticate_user!, unless: :devise_controller?
  before_action :block_registration_in_demo_sandbox
  before_action :enforce_read_only_guest_session
  helper_method :first_activity_continuation?

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
    return if role.blank?

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
