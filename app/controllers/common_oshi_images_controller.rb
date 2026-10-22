class CommonOshiImagesController < ImagesController
  private

    def owned_attachments
      visible_record_ids = OshiCommonImage.active.joins(:oshi)
        .merge(Oshi.visible_to(current_user)).select(:id)
      ActiveStorage::Attachment.where(record_type: "OshiCommonImage", name: "image",
        record_id: visible_record_ids)
    end
end
