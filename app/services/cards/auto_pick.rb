module Cards
  # Experimental, deterministic recommendation. This does not inspect image
  # pixels or send any private content to an external AI provider.
  class AutoPick
    def initialize(user:, user_oshis: nil)
      @user = user
      @user_oshis = user_oshis
    end

    def call
      rows = (@user_oshis || @user.user_oshis.includes(
        :oshi, representative_image_attachment: :blob, library_images_attachments: :blob
      ).order(:id)).to_a
      return result("data", [], "推しが未登録のため、データ表示を選びました。") if rows.empty?

      pictured, plain = rows.partition do |record|
        record.representative_image.attached? || record.library_images.attached?
      end
      selected_ids = (pictured + plain).first(4).map { |record| record.id.to_s }
      count = @user.activities.where(occurred_on: ..Date.current).count

      if pictured.size >= 2 || (pictured.any? && count < 3)
        result("photo", selected_ids, "登録画像を優先して、写真中心の構成を選びました。")
      elsif count >= 2 && @user.activities.where(occurred_on: ..Date.current).joins(:images_attachments).exists?
        result("memories", selected_ids, "活動記録に写真があるため、思い出中心の構成を選びました。")
      elsif count >= 3
        result("data", selected_ids, "活動記録が蓄積されているため、データ中心の構成を選びました。")
      elsif count.positive?
        result("memories", selected_ids, "登録した活動を見せる構成を選びました。")
      else
        result("photo", selected_ids, "活動が未登録のため、推し名を見せる写真中心の構成を選びました。")
      end
    end

    private

      def result(template, ids, reason)
        { template: template, user_oshi_ids: ids, reason: reason }
      end
  end
end
