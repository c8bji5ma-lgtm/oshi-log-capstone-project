class SubscriptionsController < ApplicationController
  before_action :set_subscription, only: [ :edit, :update, :destroy ]
  before_action :set_selectable_oshis, only: [ :new, :create, :edit, :update ]

  def index
    @date = Date.current
    @subscriptions = current_user.subscriptions.includes(:oshis).order(created_at: :desc, id: :desc)
  end

  def new
    @subscription = current_user.subscriptions.new
    @selected_oshi_ids = []
  end

  def create
    @subscription = current_user.subscriptions.new
    if save_subscription
      redirect_to subscriptions_path, notice: t("notices.subscriptions.created"), status: :see_other
    else
      render :new, formats: [ :html ], status: :unprocessable_content
    end
  end

  def edit
    @selected_oshi_ids = @subscription.oshi_ids
  end

  def update
    result = save_subscription
    if result == true
      redirect_to subscriptions_path, notice: t("notices.subscriptions.updated"), status: :see_other
    elsif result == :conflict
      render :edit, formats: [ :html ], status: :conflict
    elsif result == :bad_request
      render :edit, formats: [ :html ], status: :bad_request
    else
      render :edit, formats: [ :html ], status: :unprocessable_content
    end
  end

  def destroy
    @subscription.with_lock do
      @subscription.subscription_oshis.each(&:destroy!)
      @subscription.destroy!
    end
    redirect_to subscriptions_path, notice: t("notices.subscriptions.deleted"), status: :see_other
  rescue ActiveRecord::RecordNotDestroyed
    redirect_to subscriptions_path, alert: t("alerts.subscriptions.delete_failed"), status: :see_other
  end

  private

    def set_subscription
      @subscription = current_user.subscriptions.find(params[:id])
    rescue ActiveRecord::RecordNotFound => error
      render_user_data_not_found(error)
    end

    def set_selectable_oshis
      @selectable_oshis = current_user.oshis.order(:name, :id).to_a
    end

    def save_subscription
      input = params.require(:subscription)
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)
      attributes = input.permit(:name, :amount, :billing_cycle, :started_on, :ended_on)
      expected_lock_version = nil
      lock_version_valid = true
      if @subscription.persisted?
        @submitted_lock_version = input[:lock_version]
        expected_lock_version = parse_lock_version(@submitted_lock_version)
        lock_version_valid = !expected_lock_version.nil?
      end
      raw_ids = input.key?(:oshi_ids) ? input[:oshi_ids] : []
      @selected_oshi_ids = []
      valid_shape = raw_ids.is_a?(Array) && raw_ids.all? { |id| id.is_a?(String) && (id.blank? || id.match?(/\A[1-9][0-9]*\z/)) }
      @selected_oshi_ids = raw_ids.reject(&:blank?).map(&:to_i).uniq if valid_shape
      unless lock_version_valid
        @subscription.assign_attributes(attributes)
        @subscription.errors.add(:base, t("form_errors.invalid_edit"))
        @latest_subscription = current_user.subscriptions.includes(:oshis).find(@subscription.id)
        return :bad_request
      end
      unless valid_shape && (@selected_oshi_ids - @selectable_oshis.map(&:id)).empty?
        @subscription.assign_attributes(attributes)
        @subscription.errors.add(:base, t("form_errors.subscriptions.oshi_format"))
        return false
      end
      Subscriptions::Save.call(subscription: @subscription, attributes: attributes, oshi_ids: @selected_oshi_ids,
        expected_lock_version: expected_lock_version)
      true
    rescue ActiveRecord::StaleObjectError
      @subscription.assign_attributes(attributes)
      @subscription.errors.add(:base, t("form_errors.subscriptions.conflict"))
      @latest_subscription = current_user.subscriptions.includes(:oshis).find(@subscription.id)
      :conflict
    rescue ActiveRecord::RecordInvalid => error
      @subscription.errors.add(:base, t("form_errors.subscriptions.association", errors: error.record.errors.full_messages.join("、"))) unless error.record == @subscription
      false
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotDestroyed
      @subscription.errors.add(:base, t("form_errors.subscriptions.save_failed"))
      false
    end

    def parse_lock_version(value)
      return unless value.is_a?(String) && value.match?(/\A(?:0|[1-9][0-9]*)\z/)

      version = value.to_i
      version if version <= 2_147_483_647
    end
end
