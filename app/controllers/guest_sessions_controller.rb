# Public entrypoint only for an isolated deployment filled with demo data.
class GuestSessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: :create
  skip_before_action :enforce_read_only_guest_session, only: :create

  def create
    return head(:not_found) unless GraduationGuestSandbox.ready?
    return head(:not_found) unless GraduationGuestSandbox::ACCOUNTS.key?(params[:role])

    if user_signed_in?
      return redirect_to(root_path, alert: "別のゲストを選ぶ場合は、一度ログアウトしてください。",
        status: :see_other)
    end

    user = GraduationGuestSandbox.account(params[:role])
    return head(:not_found) unless user

    reset_session
    sign_in(:user, user)
    session[:graduation_guest_role] = params[:role]
    redirect_to root_path, notice: "閲覧専用ゲストとしてログインしました。",
      status: :see_other
  end
end
