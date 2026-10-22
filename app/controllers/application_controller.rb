class ApplicationController < ActionController::Base
  FIRST_ACTIVITY_CONTINUATION = "first_activity".freeze

  before_action :authenticate_user!, unless: :devise_controller?
  helper_method :first_activity_continuation?

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  protected

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
