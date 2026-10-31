module OshiCandidateAssets
  extend ActiveSupport::Concern

  CATALOG_LIMIT = 12

  private

    def load_oshi_candidate_assets
      @catalog_oshis = Oshi.visible_to(current_user).order(:name, :id).limit(CATALOG_LIMIT).to_a
      candidates = @oshis + @catalog_oshis
      ActiveRecord::Associations::Preloader.new(records: candidates,
        associations: { oshi_common_images: { image_attachment: :blob } }).call
      candidates = candidates.uniq(&:id)
      @registered_oshi_ids = current_user.user_oshis.where(oshi_id: candidates.map(&:id)).pluck(:oshi_id)
      @common_images = candidates.to_h do |oshi|
        [ oshi.id, oshi.oshi_common_images.select(&:active?).select { |item| item.image.attached? }.sample ]
      end
    end
end
