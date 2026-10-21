module Admin
  class OshisController < ApplicationController
    MERGE_CANDIDATE_LIMIT = 50

    before_action :require_admin!

    def index
      @oshis = Oshi.pending.order(:created_at, :id)
    end

    def approve
      update_status(:approved, "推しを承認しました。")
    end

    def reject
      update_status(:rejected, "推しを却下しました。")
    end

    def new_merge
      input = merge_selection_params
      @source_query = input[:source_query]
      @target_query = input[:target_query]
      @selected_source = selected_oshi(input[:source_id])
      @selected_target = selected_oshi(input[:target_id])
      @source_candidates, @source_has_more = merge_candidates(@source_query, @selected_source)
      @target_candidates, @target_has_more = merge_candidates(@target_query, @selected_target)
      @enough_oshis_to_merge = Oshi.limit(2).count == 2
    end

    def merge
      input = params.require(:oshi_merge)
      unless input.is_a?(ActionController::Parameters)
        raise Oshis::Merge::InvalidInput, "統合元と統合先を正しく選択してください。"
      end
      attributes = input.permit(:source_id, :target_id)
      target = Oshis::Merge.call(source_id: attributes[:source_id], target_id: attributes[:target_id])
      redirect_to admin_oshis_path, notice: "#{target.name}に推しを統合しました。", status: :see_other
    rescue ActionController::ParameterMissing
      redirect_to merge_retry_location, alert: "統合元と統合先を選択してください。", status: :see_other
    rescue Oshis::Merge::Conflict => error
      label = { started_period: "推し始め", ended_period: "推し終わり", representative_image: "代表画像" }.fetch(error.attribute, "登録情報")
      redirect_to merge_retry_location,
        alert: "ユーザーID：#{error.user_id}の#{label}が競合するため、統合を中止しました。登録内容を確認してください。", status: :see_other
    rescue Oshis::Merge::Error => error
      redirect_to merge_retry_location, alert: error.message, status: :see_other
    rescue ActiveRecord::RecordNotFound
      redirect_to merge_retry_location, alert: "対象の推しが見つかりません。選択し直してください。", status: :see_other
    rescue StandardError => error
      Rails.logger.error("Oshi merge failed: #{error.full_message}")
      redirect_to merge_retry_location, alert: "推しを統合できませんでした。登録内容を確認して再度お試しください。", status: :see_other
    end

    private

      def merge_selection_params
        input = params[:oshi_merge]
        return ActionController::Parameters.new unless input.is_a?(ActionController::Parameters)

        input.permit(:source_query, :target_query, :source_id, :target_id)
      end

      def merge_retry_location
        input = params[:oshi_merge]
        return new_merge_admin_oshis_path unless input.is_a?(ActionController::Parameters)

        selection = input.permit(:source_query, :target_query, :source_id, :target_id)
        new_merge_admin_oshis_path(oshi_merge: selection)
      end

      def selected_oshi(value)
        return if value.blank? || !value.to_s.match?(/\A[1-9][0-9]*\z/)

        Oshi.find_by(id: value)
      end

      def merge_candidates(query, selected)
        candidates = if query.present?
          Oshi.search(query).order(:name, :id).limit(MERGE_CANDIDATE_LIMIT + 1).to_a
        else
          []
        end
        has_more = candidates.size > MERGE_CANDIDATE_LIMIT
        candidates = candidates.first(MERGE_CANDIDATE_LIMIT)
        candidates << selected if selected && candidates.exclude?(selected)
        [ candidates.sort_by { |oshi| [ oshi.name, oshi.id ] }, has_more ]
      end

      def require_admin!
        return if current_user.admin?

        if html_navigation_request?
          render "errors/forbidden", formats: [ :html ], status: :forbidden
        else
          render plain: "管理者権限が必要です。", status: :forbidden
        end
      end

      def update_status(status, notice)
        oshi = Oshi.find(params[:id])
        updated = oshi.with_lock do
          oshi.pending? && oshi.update!(status: status)
        end

        if updated
          redirect_to admin_oshis_path, notice: notice, status: :see_other
        else
          redirect_to admin_oshis_path, alert: "承認待ちの推しのみ変更できます。一覧を確認してください。", status: :see_other
        end
      rescue ActiveRecord::RecordInvalid
        redirect_to admin_oshis_path, alert: "推しを更新できませんでした。登録内容を確認してください。", status: :see_other
      rescue ActiveRecord::RecordNotFound
        redirect_to admin_oshis_path, alert: "対象の推しが見つかりません。一覧を確認してください。", status: :see_other
      end
  end
end
