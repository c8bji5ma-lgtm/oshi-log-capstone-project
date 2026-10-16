class ImagesController < ApplicationController
  prepend_before_action :prepare_private_response

  def show
    attachment = owned_attachments.includes(:blob).find(params[:id])
    blob = attachment.blob
    raise ActiveRecord::RecordNotFound unless ImageAttachmentValidator::CONTENT_TYPES.include?(blob.content_type)

    # Disk storage is the configured backend in every environment. send_file
    # streams through Rack without loading the whole image or issuing a service URL.
    send_file blob.service.path_for(blob.key), type: blob.content_type,
      disposition: "inline", filename: "image.#{blob.content_type.delete_prefix('image/').sub('jpeg', 'jpg')}"
  rescue ActiveRecord::RecordNotFound, ActionController::MissingFile, ActiveStorage::InvalidKeyError
    head :not_found
  end

  private

    def owned_attachments
      attachments = ActiveStorage::Attachment.all
      attachments.where(record_type: "Profile", name: "profile_image", record_id: Profile.where(user_id: current_user.id).select(:id))
        .or(attachments.where(record_type: "UserOshi", name: [ "representative_image", "library_images" ], record_id: current_user.user_oshis.select(:id)))
        .or(attachments.where(record_type: "Activity", name: "images", record_id: current_user.activities.select(:id)))
    end

    def prepare_private_response
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Vary"] = "Cookie"
      response.headers["X-Content-Type-Options"] = "nosniff"
      head :unauthorized unless user_signed_in?
    end
end
