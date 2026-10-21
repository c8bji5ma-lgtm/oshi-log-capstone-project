class ImageAttachmentValidator < ActiveModel::EachValidator
  CONTENT_TYPES = ImageAttachmentInspector::CONTENT_TYPES
  MAX_BYTE_SIZE = ImageAttachmentInspector::MAX_BYTE_SIZE

  def validate_each(record, attribute, value)
    return unless value.attached?

    attachments = value.is_a?(ActiveStorage::Attached::Many) ? value.attachments : [ value.attachment ]
    attachments.each do |attachment|
      blob = attachment.blob
      metadata_valid = true
      unless CONTENT_TYPES.include?(blob.content_type)
        record.errors.add(attribute, "はJPEG・PNG・WebP形式の画像を指定してください")
        metadata_valid = false
      end
      if blob.byte_size > MAX_BYTE_SIZE
        record.errors.add(attribute, "は1画像あたり10 MiB以下にしてください")
        metadata_valid = false
      end
      next unless metadata_valid && attachment.new_record?
      next if ImageAttachmentInspector.inspected?(blob)

      begin
        attachable = pending_attachable(record, attribute, blob)
        attachable ? ImageAttachmentInspector.read_attachable(attachable, blob) : ImageAttachmentInspector.read(blob)
      rescue ImageAttachmentInspector::DimensionsExceeded
        record.errors.add(attribute, "は最大辺2560px・総画素数500万以下にしてください")
      rescue ImageAttachmentInspector::Invalid
        record.errors.add(attribute, "を画像として読み取れません")
      end
    end
  end

  private
    def pending_attachable(record, attribute, blob)
      change = record.attachment_changes[attribute.to_s]
      return unless change

      pending = change.respond_to?(:pending_uploads) ? change.pending_uploads : [ change ]
      subchange = pending.find { |candidate| candidate.blob == blob }
      subchange&.attachable
    end
end
