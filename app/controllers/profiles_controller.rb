class ProfilesController < ApplicationController
  def edit
    set_profile
  end

  def update
    # Serialize first saves on the user, even before a Profile row exists.
    current_user.with_lock do
      set_profile
      input = params.require(:profile)
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)

      @profile.assign_attributes(input.permit(:display_name, :introduction))
      image = input[:profile_image]
      if image.present? && !image.is_a?(ActionDispatch::Http::UploadedFile)
        @profile.errors.add(:profile_image, t("form_errors.file_required"))
        render :edit, status: :unprocessable_content
      else
        @profile.profile_image = image if image.present?
        if @profile.save
          redirect_to my_page_path, notice: t("notices.profiles.updated"), status: :see_other
        else
          render :edit, status: :unprocessable_content
        end
      end
    end
  end

  private

    def set_profile
      @profile = current_user.profile || current_user.build_profile
      @profile_image = @profile.profile_image.attachment
    end
end
