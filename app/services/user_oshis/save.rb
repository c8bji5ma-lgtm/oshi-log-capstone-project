module UserOshis
  class Save
    def self.call(user_oshi:, attributes: {}, new_images: [], representative_image_id: nil, remove_image_id: nil, clear_representative: false)
      new(user_oshi).call(attributes: attributes, new_images: new_images,
        representative_image_id: representative_image_id, remove_image_id: remove_image_id,
        clear_representative: clear_representative)
    end

    def initialize(user_oshi)
      @user_oshi = user_oshi
      @uploads = []
    end

    def call(attributes:, new_images:, representative_image_id:, remove_image_id:, clear_representative:)
      UserOshi.transaction(requires_new: true) do
        # Reload under the same lock for uploads, selections and deletions.
        @user_oshi.lock! if @user_oshi.persisted?
        attributes = attributes.to_h.symbolize_keys
        replacement = attributes.delete(:representative_image)
        @user_oshi.assign_attributes(attributes)
        files = upload_files(new_images)
        files << replacement if replacement.present?
        unless files.all? { |file| file.is_a?(ActionDispatch::Http::UploadedFile) }
          invalid_image("はファイルとして選択してください。")
        end

        if remove_image_id
          remove_image(remove_image_id, clear_representative)
        elsif representative_image_id
          select_representative(find_image(representative_image_id).blob)
        end

        if files.any?
          blobs = files.map { |file| build_blob(file) }
          @user_oshi.library_images = @user_oshi.library_images.blobs.to_a + blobs
          if replacement.present? || !@user_oshi.representative_image.attached?
            select_representative(replacement.present? ? blobs.last : blobs.first)
          end
        end

        # Validate everything before writing any bytes. Upload BEFORE saving so
        # a disk failure can roll back the complete operation. Assigning blobs
        # (rather than files) leaves no Active Storage after_commit uploads.
        @user_oshi.oshi.save! if @user_oshi.oshi.new_record?
        @user_oshi.validate!
        @uploads.each { |blob, file| blob.upload_without_unfurling(file.open) }
        raise ActiveRecord::RecordInvalid, @user_oshi unless @user_oshi.save
        @user_oshi
      end
    rescue StandardError => error
      @uploads.each do |blob, _file|
        blob.delete unless ActiveStorage::Blob.exists?(key: blob.key)
      end
      if error.is_a?(IOError) || error.is_a?(SystemCallError) || error.is_a?(ActiveStorage::Error)
        invalid_image("を保存できませんでした。画像を選び直して再度お試しください。")
      end
      raise
    end

    private

      def upload_files(value)
        return [] if value.nil? || value == ""
        invalid_image("は複数ファイルとして選択してください。") unless value.is_a?(Array)
        value.reject { |file| file == "" }
      end

      def build_blob(file)
        blob = ActiveStorage::Blob.build_after_unfurling(io: file.open,
          filename: file.original_filename, content_type: file.content_type)
        @uploads << [ blob, file ]
        blob
      end

      def invalid_image(message)
        @user_oshi.errors.add(:library_images, message)
        raise ActiveRecord::RecordInvalid, @user_oshi
      end

      def find_image(id)
        unless id.is_a?(String) && id.match?(/\A[1-9][0-9]*\z/)
          raise ActiveRecord::RecordNotFound
        end
        @user_oshi.image_library.find { |image| image.id.to_s == id } || raise(ActiveRecord::RecordNotFound)
      end

      def select_representative(blob)
        previous = @user_oshi.representative_image.blob
        return if previous == blob

        # The old representative may predate the library. Preserve its blob
        # BEFORE has_one replacement destroys the old attachment reference.
        if previous && !@user_oshi.library_images.blobs.include?(previous)
          @user_oshi.library_images = @user_oshi.library_images.blobs.to_a + [ previous ]
        end
        @user_oshi.representative_image = blob
      end

      def remove_image(id, clear_representative)
        image = find_image(id)
        blob = image.blob
        if @user_oshi.representative_image.blob == blob
          invalid_image("の削除には代表画像の解除を明示してください。") unless clear_representative
          @user_oshi.representative_image.detach
        end
        @user_oshi.library_images.attachments.select { |attachment| attachment.blob_id == blob.id }.each(&:delete)
        @user_oshi.reload
        # Delete only unreferenced originals after commit. Blob#purge also has
        # an FK guard against references added by another record in the interim.
        ActiveRecord.after_all_transactions_commit { blob.purge_later unless blob.attachments.exists? }
      end
  end
end
