class ActivitiesController < ApplicationController
  before_action :set_activity, only: [ :show, :edit, :update, :destroy ]
  before_action :set_selectable_oshis, only: [ :index, :new, :create, :edit, :update ]
  before_action :set_selectable_emotions, only: [ :new, :create, :edit, :update ]

  def index
    @filters = {}
    @filter_errors = []
    %w[year month through oshi_id activity_type q].each do |key|
      value = params[key]
      if value.nil? || value.is_a?(String)
        @filters[key] = value.to_s
      else
        @filters[key] = ""
        @filter_errors << t("form_errors.activities.filter_format")
      end
    end
    scope = current_user.activities
    year = @filters["year"]
    if year.present?
      if year.match?(/\A[0-9]{4}\z/) && year.to_i.positive?
        first = Date.new(year.to_i, 1, 1)
        scope = scope.where(occurred_on: first...first.next_year)
      else
        @filter_errors << t("form_errors.activities.year_format")
      end
    end
    month = @filters["month"]
    @filter_errors << t("form_errors.activities.year_and_month") if year.present? && month.present?
    if month.present?
      begin
        raise ArgumentError unless month.match?(/\A[0-9]{4}-(0[1-9]|1[0-2])\z/) && month[0, 4].to_i.positive?
        first = Date.strptime(month, "%Y-%m")
        scope = scope.where(occurred_on: first...first.next_month)
      rescue ArgumentError
        @filter_errors << t("form_errors.activities.month_format")
      end
    end
    if @filters["oshi_id"].present?
      id = positive_id(@filters["oshi_id"])
      if id && @selectable_oshis.any? { |oshi| oshi.id == id }
        scope = scope.joins(:activity_oshis).where(activity_oshis: { oshi_id: id }).distinct
      else
        @filter_errors << t("form_errors.activities.filter_oshi")
      end
    end
    through = @filters["through"]
    if through.present?
      begin
        through_date = Date.iso8601(through)
        raise ArgumentError unless through == through_date.iso8601
        scope = scope.where(occurred_on: ..through_date)
      rescue ArgumentError
        @filter_errors << t("form_errors.activities.period_end")
      end
    end
    category = @filters["activity_type"]
    if category.present?
      if Activity::ACTIVITY_TYPES.include?(category)
        scope = scope.where(activity_type: category)
      else
        @filter_errors << t("form_errors.activities.category")
      end
    end
    if @filters["q"].present?
      pattern = "%#{Activity.sanitize_sql_like(@filters['q'])}%"
      scope = scope.where("activities.title ILIKE :query OR activities.place ILIKE :query OR activities.memo ILIKE :query", query: pattern)
    end
    page = Activities::KeysetPage.call(scope: (@filter_errors.empty? ? scope : scope.none).includes(:emotions),
      cursor: params[:cursor], direction: params[:direction], purpose: "index")
    @activities = page.records
    @older_cursor = page.older_cursor if page.has_older
    @newer_cursor = page.newer_cursor if page.has_newer
    render :index, status: :bad_request if @filter_errors.any?
  rescue Activities::KeysetPage::InvalidCursor
    @activities = []
    @filter_errors << t("form_errors.activities.page")
    render :index, status: :bad_request
  end

  def new
    @activity = current_user.activities.new(occurred_on: Date.current)
    @selected_oshi_ids = initial_oshi_selection
    @selected_emotion_ids = []
    @existing_images = []
    if params.key?(:initial_oshi_id) && @selected_oshi_ids.empty?
      @activity.errors.add(:base, t("form_errors.activities.first_oshi"))
      render :new, status: :bad_request
    end
  end

  def create
    @activity = current_user.activities.new
    @existing_images = []
    if save_activity
      redirect_to activities_path, notice: t("notices.activities.created"), status: :see_other
    else
      render :new, status: :unprocessable_content
    end
  end

  def show
    @activity.oshis.load
  end

  def edit
    @selected_oshi_ids = @activity.oshi_ids
    @selected_emotion_ids = @activity.emotion_ids
  end

  def update
    result = save_activity
    if result == true
      redirect_to activity_path(@activity), notice: t("notices.activities.updated"), status: :see_other
    elsif result == :conflict
      render :edit, formats: [ :html ], status: :conflict
    elsif result == :bad_request
      render :edit, formats: [ :html ], status: :bad_request
    else
      render :edit, formats: [ :html ], status: :unprocessable_content
    end
  end

  def destroy
    destroy_activity
    redirect_to activities_path, notice: t("notices.activities.deleted"), status: :see_other
  rescue ActiveRecord::RecordNotDestroyed
    redirect_to activity_path(@activity), alert: t("alerts.activities.delete_failed"), status: :see_other
  end

  private

    def set_activity
      @activity = current_user.activities.with_attached_images.find(params[:id])
      @existing_images = @activity.images.attachments.to_a
    rescue ActiveRecord::RecordNotFound => error
      render_user_data_not_found(error)
    end

    def set_selectable_oshis
      @selectable_oshis = current_user.oshis.order(:name, :id).to_a
    end

    def set_selectable_emotions
      @selectable_emotions = Emotion.ordered.to_a
    end

    def positive_id(value)
      value.to_i if value.is_a?(String) && value.match?(/\A[1-9][0-9]*\z/)
    end

    def initial_oshi_selection
      id = positive_id(params[:initial_oshi_id])
      id && @selectable_oshis.any? { |oshi| oshi.id == id } ? [ id ] : []
    end

    def save_activity
      input = params.require(:activity)
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)
      attributes = input.permit(:occurred_on, :activity_type, :title, :place, :amount, :memo)
      expected_lock_version = nil
      lock_version_valid = true
      if @activity.persisted?
        @submitted_lock_version = input[:lock_version]
        expected_lock_version = parse_lock_version(@submitted_lock_version)
        lock_version_valid = !expected_lock_version.nil?
      end
      raw_ids = input[:oshi_ids] || []
      @selected_oshi_ids = []
      ids_valid = raw_ids.is_a?(Array) && raw_ids.all? { |id| id == "" || positive_id(id) }
      @selected_oshi_ids = raw_ids.reject { |id| id == "" }.map { |id| positive_id(id) }.uniq if ids_valid
      raw_emotion_ids = input.fetch(:emotion_ids, @activity.emotion_ids.map(&:to_s))
      emotions_valid = raw_emotion_ids.is_a?(Array) && raw_emotion_ids.all? { |id| id == "" || positive_id(id) }
      @selected_emotion_ids = emotions_valid ? raw_emotion_ids.reject { |id| id == "" }.map { |id| positive_id(id) }.uniq : []
      emotions_valid &&= (@selected_emotion_ids - @selectable_emotions.map(&:id)).empty?
      uploads = input[:images] || []
      images_valid = uploads.is_a?(Array) && uploads.all? { |image| image == "" || image.is_a?(ActionDispatch::Http::UploadedFile) }
      allowed = @selectable_oshis.map(&:id)
      selection_valid = ids_valid && (@selected_oshi_ids - allowed).empty?
      unless lock_version_valid
        @activity.assign_attributes(attributes)
        @activity.errors.add(:base, t("form_errors.invalid_edit"))
        @latest_activity = current_user.activities.with_attached_images.includes(:oshis, :emotions).find(@activity.id)
        @existing_images = @latest_activity.images.attachments.to_a
        return :bad_request
      end
      if !selection_valid || @selected_oshi_ids.empty? || !images_valid || !emotions_valid
        @activity.assign_attributes(attributes)
        @activity.errors.add(:base, t("form_errors.activities.oshi_format")) unless selection_valid
        @activity.errors.add(:base, t("form_errors.activities.oshi_required")) if ids_valid && @selected_oshi_ids.empty?
        @activity.errors.add(:images, t("form_errors.file_required")) unless images_valid
        @activity.errors.add(:emotion_ids, t("form_errors.activities.emotion_format")) unless emotions_valid
        return false
      end
      Activities::Save.call(activity: @activity, attributes: attributes, oshi_ids: @selected_oshi_ids,
        emotion_ids: input.key?(:emotion_ids) ? @selected_emotion_ids : nil,
        new_images: uploads.reject { |image| image == "" }, expected_lock_version: expected_lock_version)
      true
    rescue ActiveRecord::StaleObjectError
      @activity.assign_attributes(attributes)
      @activity.errors.add(:base, t("form_errors.activities.conflict"))
      @latest_activity = current_user.activities.with_attached_images.includes(:oshis, :emotions).find(@activity.id)
      @existing_images = @latest_activity.images.attachments.to_a
      :conflict
    rescue ActiveRecord::RecordInvalid
      false
    end

    def parse_lock_version(value)
      return unless value.is_a?(String) && value.match?(/\A(?:0|[1-9][0-9]*)\z/)

      version = value.to_i
      version if version <= 2_147_483_647
    end

    def destroy_activity
      @activity.with_lock do
        # Only whole-record deletion bypasses the last-oshi protection.
        ActivityOshi.where(activity_id: @activity.id).delete_all
        @activity.destroy!
      end
    end
end
