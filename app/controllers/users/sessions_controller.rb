module Users
  class SessionsController < Devise::SessionsController
    def destroy
      session.delete(:graduation_guest_role)
      super
    end
  end
end
