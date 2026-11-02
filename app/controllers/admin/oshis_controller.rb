module Admin
  class OshisController < ApplicationController
    MERGE_CANDIDATE_LIMIT = 50

    before_action :require_admin!

    def index
      @oshis = Oshi.pending.order(:created_at, :id)
    end

    def approve
      update_status(:approved, t("notices.oshis.approved"))
    end

    def reject
      update_status(:rejected, t("notices.oshis.rejected"))
    end

    def manage
      @query = deletion_query
      scope = @query.present? ? Oshi.search(@query) : Oshi.all
      records = scope.order(:name, :id).limit(51).to_a
      @has_more = records.size > 50
      @managed_oshis = records.first(50)
    end

    def confirm_destroy
      @query = deletion_query
      @oshi = Oshis::Delete.find(params[:id])
      @references = Oshis::Delete.references(@oshi)
      @deletion_read_only = session[:graduation_guest_role].present? ||
        (GraduationGuestSandbox.enabled? && GraduationGuestSandbox.reserved_email?(current_user.email))
      @confirmation = Oshis::Delete.confirmation(@oshi) if @references.empty? && !@deletion_read_only
    rescue ActiveRecord::RecordNotFound => error
      render_user_data_not_found(error)
    end

    def destroy
      record = delete_oshi
      return if performed?

      redirect_to manage_admin_oshis_path(q: deletion_query),
        notice: t("admin_oshi_deletion.deleted", name: record.name), status: :see_other
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
        raise Oshis::Merge::InvalidInput, t("alerts.oshis.merge_invalid")
      end
      attributes = input.permit(:source_id, :target_id)
      target = Oshis::Merge.call(source_id: attributes[:source_id], target_id: attributes[:target_id])
      redirect_to admin_oshis_path, notice: t("notices.oshis.merged", name: target.name), status: :see_other
    rescue ActionController::ParameterMissing
      redirect_to merge_retry_location, alert: t("alerts.oshis.merge_missing"), status: :see_other
    rescue Oshis::Merge::Conflict => error
      label = { started_period: t("ui.labels.started_period"), ended_period: t("ui.labels.finished_period"), representative_image: t("ui.labels.representative_image") }.fetch(error.attribute, t("ui.labels.registration_information"))
      redirect_to merge_retry_location,
        alert: t("alerts.oshis.merge_conflict", user_id: error.user_id, label: label), status: :see_other
    rescue Oshis::Merge::Error => error
      redirect_to merge_retry_location, alert: error.message, status: :see_other
    rescue ActiveRecord::RecordNotFound
      redirect_to merge_retry_location, alert: t("alerts.oshis.merge_not_found"), status: :see_other
    rescue StandardError => error
      Rails.logger.error("Oshi merge failed: #{error.full_message}")
      redirect_to merge_retry_location, alert: t("alerts.oshis.merge_failed"), status: :see_other
    end

    private

      def deletion_query
        params[:q].is_a?(String) ? params[:q].strip[0, 255] : ""
      end

      def delete_oshi
        Oshis::Delete.call(id: params[:id], confirmation: params[:oshi_delete_confirmation])
      rescue Oshis::Delete::InUse => error
        labels = error.references.map { |name| t("admin_oshi_deletion.references.#{name}") }.join("、")
        refuse_deletion(t("admin_oshi_deletion.in_use_detail", references: labels))
      rescue Oshis::Delete::InvalidConfirmation
        refuse_deletion(t("admin_oshi_deletion.confirm_again"))
      rescue ActiveRecord::RecordNotFound => error
        render_user_data_not_found(error)
      rescue ActiveRecord::InvalidForeignKey
        refuse_deletion(t("admin_oshi_deletion.references_changed"))
      rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
        refuse_deletion(t("admin_oshi_deletion.busy"))
      rescue ActiveRecord::RecordNotDestroyed
        refuse_deletion(t("admin_oshi_deletion.failed"), confirm: false)
      rescue StandardError => error
        Rails.logger.error("Oshi deletion failed: #{error.class.name}")
        refuse_deletion(t("admin_oshi_deletion.failed"), confirm: false)
      end

      def refuse_deletion(message, confirm: true)
        location = if confirm
          confirm_destroy_admin_oshi_path(params[:id], q: deletion_query)
        else
          manage_admin_oshis_path(q: deletion_query)
        end
        redirect_to location, alert: message, status: :see_other
      end


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
          render plain: t("alerts.oshis.admin_required"), status: :forbidden
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
          redirect_to admin_oshis_path, alert: t("alerts.oshis.pending_only"), status: :see_other
        end
      rescue ActiveRecord::RecordInvalid
        redirect_to admin_oshis_path, alert: t("alerts.oshis.update_failed"), status: :see_other
      rescue ActiveRecord::RecordNotFound
        redirect_to admin_oshis_path, alert: t("alerts.oshis.not_found"), status: :see_other
      end
  end
end
