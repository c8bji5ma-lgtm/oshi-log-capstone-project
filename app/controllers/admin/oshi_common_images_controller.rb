module Admin
  class OshiCommonImagesController < ApplicationController
    SEARCH_LIMIT = 50
    before_action :require_admin!
    before_action :set_record, only: [ :edit, :update, :destroy ]

    def index
      @query = params[:q]
      @oshis = @query.present? ? Oshi.search(@query).order(:name, :id).limit(SEARCH_LIMIT) : Oshi.none
      @oshis = @oshis.includes(oshi_common_images: { image_attachment: :blob })
    end

    def new
      @oshi = Oshi.find(params[:oshi_id])
      @common_image = @oshi.oshi_common_images.new(rights_confirmed_at: Time.current)
    end

    def create
      @oshi = Oshi.find(params.require(:oshi_common_image).require(:oshi_id))
      @common_image = OshiCommonImages::Create.call(oshi: @oshi, administrator: current_user,
        attributes: common_image_params, file: params.dig(:oshi_common_image, :image))
      redirect_to admin_oshi_common_images_path(q: @oshi.name), notice: "共通画像を登録しました。", status: :see_other
    rescue ActiveRecord::RecordInvalid => error
      @common_image = error.record
      render :new, status: :unprocessable_content
    end

    def edit
      @oshi = @common_image.oshi
    end

    def update
      @common_image.with_lock do
        raise ActiveRecord::StaleObjectError.new(@common_image, "update") unless expected_lock_version == @common_image.lock_version

        @common_image.update!(common_image_params)
      end
      redirect_to admin_oshi_common_images_path(q: @common_image.oshi.name), notice: "共通画像情報を更新しました。", status: :see_other
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError
      @oshi = @common_image.oshi
      @common_image.errors.add(:base, "他の更新と競合しました。内容を確認してください。") if @common_image.errors.empty?
      render :edit, status: :unprocessable_content
    end

    def destroy
      oshi_name = @common_image.oshi.name
      @common_image.with_lock do
        raise ActiveRecord::StaleObjectError.new(@common_image, "destroy") unless expected_lock_version == @common_image.lock_version

        @common_image.destroy!
      end
      redirect_to admin_oshi_common_images_path(q: oshi_name), notice: "共通画像を削除しました。", status: :see_other
    rescue ActiveRecord::StaleObjectError
      redirect_to admin_oshi_common_images_path(q: oshi_name), alert: "他の更新と競合しました。内容を確認してください。", status: :see_other
    end

    private

      def set_record
        @common_image = OshiCommonImage.includes(:oshi, image_attachment: :blob).find(params[:id])
      end

      def common_image_params
        params.require(:oshi_common_image).permit(:source_url, :creator_name, :license_name,
          :attribution_text, :usage_notes, :rights_confirmed_at, :active)
      end

      def expected_lock_version
        Integer(params.require(:oshi_common_image).require(:lock_version), 10)
      rescue ArgumentError
        raise ActionController::BadRequest, "lock_versionが不正です"
      end

      def require_admin!
        return if current_user.admin?

        if html_navigation_request?
          render "errors/forbidden", formats: [ :html ], status: :forbidden
        else
          render plain: "管理者権限が必要です。", status: :forbidden
        end
      end
  end
end
