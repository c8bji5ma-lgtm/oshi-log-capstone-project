module Activities
  class Save
    # Pass a new or unchanged persisted Activity and scalar attributes separately.
    # Omitted oshi_ids preserves existing links; [] explicitly requests no links.
    # new_images appends uploads under the parent lock; omitted or empty retains images.
    # Returns the saved Activity; failures raise and roll back all database changes.
    # Omitted emotion_ids preserves tags; [] clears them within the same transaction.
    # Every linked Oshi must be registered to the Activity owner through UserOshi.
    # expected_lock_version is supplied by persisted edit forms. Programmatic
    # callers may omit it when they are not acting on a user-visible snapshot.
    def self.call(activity:, attributes: {}, oshi_ids: nil, emotion_ids: nil, new_images: [], expected_lock_version: nil)
      Activity.transaction do
        starting_lock_version = nil
        if activity.persisted?
          activity.lock!
          starting_lock_version = activity.lock_version
          if !expected_lock_version.nil? && expected_lock_version != starting_lock_version
            raise ActiveRecord::StaleObjectError.new(activity, "update")
          end
          activity.activity_oshis.reload
        end

        ids = if oshi_ids.nil?
          activity.activity_oshis.map(&:oshi_id)
        else
          oshi_ids.map { |id| Oshi.type_for_attribute("id").cast(id) }.uniq
        end

        activity.assign_attributes(attributes)
        registered_ids = UserOshi.where(user_id: activity.user_id || activity.user&.id, oshi_id: ids).pluck(:oshi_id)
        if (ids - registered_ids).any?
          activity.errors.add(:activity_oshis, "must belong to oshis registered by the activity user")
          raise ActiveRecord::RecordInvalid, activity
        end
        unless emotion_ids.nil?
          activity.emotion_ids = emotion_ids.map { |id| Emotion.type_for_attribute("id").cast(id) }.uniq
        end
        uploads = Array(new_images).compact_blank
        attribute_uploads = if attributes.respond_to?(:[]) && (images = attributes[:images] || attributes["images"])
          Array(images).compact_blank
        else
          []
        end
        if ImageUploadBatch.too_large?(uploads + attribute_uploads)
          activity.errors.add(:images, "は1回の送信合計を10 MiB以下にしてください。分けて追加できます")
          raise ActiveRecord::RecordInvalid, activity
        end
        activity.images = activity.images.blobs.to_a + uploads if uploads.any?
        if ids.empty?
          activity.errors.add(:activity_oshis, "must include at least one oshi")
          raise ActiveRecord::RecordInvalid, activity
        end

        existing_ids = activity.activity_oshis.map(&:oshi_id)
        (ids - existing_ids).each { |id| activity.activity_oshis.build(oshi_id: id) }
        activity.save!
        ids = activity.activity_oshis.reject(&:destroyed?).map(&:oshi_id) if oshi_ids.nil?

        # Additions have been saved before any removal, including A -> B changes.
        activity.activity_oshis.where.not(oshi_id: ids).each(&:destroy!)
        activity.activity_oshis.reload
        unless activity.activity_oshis.exists?
          activity.errors.add(:activity_oshis, "must include at least one oshi")
          raise ActiveRecord::RecordInvalid, activity
        end

        if starting_lock_version && activity.lock_version == starting_lock_version
          activity.touch
        end

        activity
      end
    end
  end
end
