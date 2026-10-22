module Oshis
  class Merge
    class Error < StandardError; end
    class InvalidInput < Error; end
    class ConcurrentChange < Error; end

    class Conflict < Error
      attr_reader :user_id, :attribute

      def initialize(user_id:, attribute:)
        @user_id = user_id
        @attribute = attribute
        super("ユーザー#{user_id}の#{attribute}が競合しています。")
      end
    end

    # Returns the surviving Oshi. Domain and ActiveRecord errors propagate to the
    # caller after rollback. Existing blobs/files are never uploaded or purged.
    def self.call(source_id:, target_id:)
      new(source_id: source_id, target_id: target_id).call
    end

    def initialize(source_id:, target_id:)
      @source_id = positive_id(source_id)
      @target_id = positive_id(target_id)
      raise InvalidInput, "統合元と統合先は別の推しを選択してください。" if @source_id == @target_id

      @oshi_ids = [ @source_id, @target_id ].sort
    end

    def call
      # A savepoint also protects callers that rescue inside an outer transaction.
      result = Oshi.transaction(requires_new: true) do
        lock_records
        check_conflicts
        merge_user_oshis
        merge_links(@activity_oshis, :activity_id)
        merge_links(@subscription_oshis, :subscription_id)
        merge_common_images
        merge_aliases
        ensure_source_unreferenced
        @source.destroy!
        @target
      end
      result || raise(Error, "統合が取り消されました。")
    end

    private

      def positive_id(value)
        valid = (value.is_a?(Integer) && value.positive?) ||
          (value.is_a?(String) && value.match?(/\A[1-9][0-9]*\z/))
        raise InvalidInput, "統合元・統合先には正しい推しIDを指定してください。" unless valid

        value.to_i
      end

      def pair_scope(model)
        model.where(oshi_id: @oshi_ids)
      end

      def lock_records
        activity_ids = pair_scope(ActivityOshi).distinct.pluck(:activity_id).sort
        subscription_ids = pair_scope(SubscriptionOshi).distinct.pluck(:subscription_id).sort
        @user_oshis = pair_scope(UserOshi).order(:id).lock.to_a

        # Existing activity/subscription save and destroy paths lock the parent
        # before changing joins. Follow that order, rather than Oshi -> parent.
        locked_activity_ids = Activity.where(id: activity_ids).order(:id).lock.map(&:id)
        locked_subscription_ids = Subscription.where(id: subscription_ids).order(:id).lock.map(&:id)
        oshis = Oshi.where(id: @oshi_ids).order(:id).lock.index_by(&:id)
        @source = oshis.fetch(@source_id) { raise ActiveRecord::RecordNotFound, "統合元の推しが見つかりません。" }
        @target = oshis.fetch(@target_id) { raise ActiveRecord::RecordNotFound, "統合先の推しが見つかりません。" }

        @activity_oshis = pair_scope(ActivityOshi).order(:id).lock.to_a
        @subscription_oshis = pair_scope(SubscriptionOshi).order(:id).lock.to_a
        @aliases = pair_scope(OshiAlias).order(:id).lock.to_a
        @common_images = pair_scope(OshiCommonImage).order(:id).lock.to_a
        if @common_images.size > OshiCommonImage::LIMIT_PER_OSHI
          raise Error, "統合後の共通画像が#{OshiCommonImage::LIMIT_PER_OSHI}枚を超えるため、先に整理してください。"
        end
        unchanged = pair_scope(UserOshi).order(:id).pluck(:id) == @user_oshis.map(&:id) &&
          @activity_oshis.map(&:activity_id).uniq.sort == locked_activity_ids &&
          @subscription_oshis.map(&:subscription_id).uniq.sort == locked_subscription_ids
        raise ConcurrentChange, "関連データが変更されました。再度統合を実行してください。" unless unchanged

        @attachments = ActiveStorage::Attachment.where(record_type: "UserOshi", record_id: @user_oshis.map(&:id))
          .order(:id).lock.to_a.group_by(&:record_id)
        @user_oshis.each do |record|
          images = @attachments.fetch(record.id, [])
          if images.size > 1 || images.any? { |image| image.name != "representative_image" }
            raise Conflict.new(user_id: record.user_id, attribute: :representative_image)
          end
        end
      end

      def user_pairs
        @user_oshis.group_by(&:user_id).values.map do |records|
          [ records.find { |record| record.oshi_id == @source_id },
            records.find { |record| record.oshi_id == @target_id } ]
        end
      end

      def image_for(record)
        @attachments.fetch(record.id, []).first
      end

      def check_conflicts
        user_pairs.each do |source, target|
          next unless source && target

          [ :started_period, :ended_period ].each do |attribute|
            left, right = source.public_send(attribute), target.public_send(attribute)
            if left.present? && right.present? && left != right
              raise Conflict.new(user_id: source.user_id, attribute: attribute)
            end
          end
          left, right = image_for(source), image_for(target)
          if left && right && left.blob_id != right.blob_id
            raise Conflict.new(user_id: source.user_id, attribute: :representative_image)
          end
        end
      end

      def merge_user_oshis
        user_pairs.each do |source, target|
          next unless source

          unless target
            source.update!(oshi_id: @target_id)
            next
          end

          attributes = [ :started_period, :ended_period ].each_with_object({}) do |attribute, values|
            if target.public_send(attribute).blank? && source.public_send(attribute).present?
              values[attribute] = source.public_send(attribute)
            end
          end
          target.update!(attributes) if attributes.any?
          source_image, target_image = image_for(source), image_for(target)
          if source_image
            if target_image
              # Only a redundant reference to the SAME blob is deleted. Avoid
              # destroy's after_commit purge callback; retain the target image.
              source_image.delete
            else
              source_image.update!(record: target)
            end
          end
          # Clear attachment caches before dependent callbacks run on deletion.
          source.reload
          if source.representative_image.attached?
            raise ConcurrentChange, "代表画像が変更されました。再度統合を実行してください。"
          end
          source.destroy!
        end
      end

      def merge_links(records, parent_key)
        targets = records.select { |record| record.oshi_id == @target_id }.index_by(&parent_key)
        records.select { |record| record.oshi_id == @source_id }.each do |record|
          if targets.key?(record.public_send(parent_key))
            # An Activity retains its target link, so its last-link guard holds.
            record.destroy!
          else
            record.update!(oshi_id: @target_id)
          end
        end
      end

      def merge_common_images
        @common_images.select { |record| record.oshi_id == @source_id }.each do |record|
          record.update!(oshi_id: @target_id)
        end
      end

      def merge_aliases
        names = @aliases.select { |record| record.oshi_id == @target_id }.map(&:alias_name)
        @aliases.select { |record| record.oshi_id == @source_id }.each do |record|
          if names.include?(record.alias_name)
            record.destroy!
          else
            record.update!(oshi_id: @target_id)
            names << record.alias_name
          end
        end
        @target.oshi_aliases.create!(alias_name: @source.name) unless names.include?(@source.name)
      end

      def ensure_source_unreferenced
        if [ UserOshi, ActivityOshi, SubscriptionOshi, OshiAlias, OshiCommonImage ].any? { |model| model.exists?(oshi_id: @source_id) }
          raise ConcurrentChange, "統合元への参照が変更されました。再度統合を実行してください。"
        end
      end
  end
end
