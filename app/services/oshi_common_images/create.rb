module OshiCommonImages
  class Create
    def self.call(oshi:, administrator:, attributes:, file:)
      new(oshi, administrator).call(attributes, file)
    end

    def initialize(oshi, administrator)
      @oshi = oshi
      @administrator = administrator
      @uploaded_blob = nil
    end

    def call(attributes, file)
      record = nil
      Oshi.transaction(requires_new: true) do
        @oshi.lock!
        if @oshi.oshi_common_images.count >= OshiCommonImage::LIMIT_PER_OSHI
          record = @oshi.oshi_common_images.new(attributes)
          record.errors.add(:base, "共通画像は1推しにつき最大#{OshiCommonImage::LIMIT_PER_OSHI}枚です")
          raise ActiveRecord::RecordInvalid, record
        end

        record = @oshi.oshi_common_images.new(attributes.merge(registered_by_user: @administrator))
        build_image(record, file)
        record.validate!
        @uploaded_blob.upload_without_unfurling(file.open)
        record.save!
      end
      record
    rescue StandardError
      cleanup_upload
      raise
    end

    private

      def build_image(record, file)
        unless file.is_a?(ActionDispatch::Http::UploadedFile)
          record.errors.add(:image, "はファイルとして選択してください")
          raise ActiveRecord::RecordInvalid, record
        end
        @uploaded_blob = ActiveStorage::Blob.build_after_unfurling(
          io: file.open, filename: file.original_filename, content_type: file.content_type
        )
        ImageAttachmentInspector.read_attachable(file, @uploaded_blob)
        record.image = @uploaded_blob
      rescue ImageAttachmentInspector::DimensionsExceeded
        record.errors.add(:image, "は最大辺2560px・総画素数500万以下にしてください")
        raise ActiveRecord::RecordInvalid, record
      rescue IOError, SystemCallError, ActiveStorage::Error, ImageAttachmentInspector::Invalid
        record.errors.add(:image, "を読み取れませんでした")
        raise ActiveRecord::RecordInvalid, record
      end

      def cleanup_upload
        return unless @uploaded_blob

        persisted = ActiveStorage::Blob.find_by(key: @uploaded_blob.key)
        if persisted
          persisted.purge unless persisted.attachments.exists?
        else
          @uploaded_blob.delete
        end
      rescue ActiveStorage::FileNotFoundError, Errno::ENOENT
        nil
      end
  end
end
