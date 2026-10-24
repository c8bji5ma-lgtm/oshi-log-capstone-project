require "digest"

class CardsController < ApplicationController
  LIFETIME = 15.minutes
  PURPOSE = "photo-card-download-v2"
  RETRY_AFTER = 5
  MAX_JSON_BYTES = 256.kilobytes

  prepend_before_action :private_response

  def new
    return redirect_to(edit_profile_path, alert: "カードを作る前にプロフィールを保存してください。") unless current_user.profile

    @user_oshis = current_user.user_oshis.includes(:oshi, representative_image_attachment: :blob, library_images_attachments: :blob).order(:id)
    @initial_user_oshi_id = initial_user_oshi_id
  end

  def memories
    page = Activities::KeysetPage.call(scope: Cards::Memory.candidates(current_user),
      cursor: params[:cursor], direction: "older", purpose: "card-memories")
    ids = page.records.map(&:id)
    oshi_counts = ActivityOshi.where(activity_id: ids).group(:activity_id).count
    image_counts = ActiveStorage::Attachment.where(record_type: "Activity", name: "images", record_id: ids).group(:record_id).count
    activities = page.records.map do |activity|
      { id: activity.id.to_s, date: activity.occurred_on.strftime("%Y.%m.%d"), title: activity.title,
        category: activity.activity_type, oshi_count: oshi_counts.fetch(activity.id, 0),
        image_count: image_counts.fetch(activity.id, 0) }
    end
    render_bounded_json(activities:, next_cursor: (page.older_cursor if page.has_older), has_more: page.has_older)
  rescue Activities::KeysetPage::InvalidCursor
    render_error("ページ情報が正しくありません。活動記録を最初から読み込み直してください。", :bad_request)
  end

  def memory_materials
    activity = Cards::Memory.candidates(current_user).find(params[:activity_id])
    page = Cards::MemoryMaterialsPage.call(activity:, kind: params[:kind], cursor: params[:cursor])
    items = case params[:kind]
    when "oshis"
      page.records.map { |link| { id: link.oshi_id.to_s, name: link.oshi.name } }
    when "images"
      page.records.map { |image| { id: image.id.to_s, url: protected_image_path(image) } }
    end
    render_bounded_json(activity_id: activity.id.to_s, kind: params[:kind], items:,
      next_cursor: page.next_cursor, has_more: page.has_more, total_count: page.total_count)
  rescue ActiveRecord::RecordNotFound
    render_error("活動記録が見つかりません。", :not_found)
  rescue Cards::MemoryMaterialsPage::InvalidCursor
    render_error("関連情報のページ情報が正しくありません。最初から読み込み直してください。", :bad_request)
  rescue Cards::MemoryMaterialsPage::InvalidKind
    render_error("関連情報の種類が正しくありません。", :bad_request)
  end

  def statistics
    date = Date.current
    years = OshiData::Summary.available_years(user: current_user, date: date)
    oshis = current_user.user_oshis.includes(:oshi).map(&:oshi).sort_by { |oshi| [ oshi.name, oshi.id ] }
    render json: { year: date.year.to_s, years: years.map(&:to_s), oshis: oshis.map { |oshi| { id: oshi.id.to_s, name: oshi.name } } }
  end

  def create
    settings = card_settings
    fingerprint, png = Cards::RenderGate.with do
      card = card_renderer(settings)
      source = card.fingerprint
      rendered = card.render
      raise SourceChanged unless card_renderer(settings).fingerprint == source
      [ source, rendered ]
    end

    generated_at = Time.current
    payload = {
      "user_id" => current_user.id, "auth_context" => auth_context,
      "settings" => settings.stringify_keys, "source" => fingerprint,
      "png_sha256" => Digest::SHA256.hexdigest(png), "byte_size" => png.bytesize,
      "expires_at" => (generated_at + LIFETIME).to_i
    }
    response.headers["X-Card-Receipt"] = verifier.generate(payload, purpose: PURPOSE)
    response.headers["X-Card-Expires-At"] = payload["expires_at"].to_s
    response.headers["X-PNG-SHA256"] = payload["png_sha256"]
    send_data png, type: "image/png", disposition: "inline"
  rescue UnsupportedTemplate
    render_error("このテンプレートは利用できません。", :unprocessable_content)
  rescue Cards::Data::InvalidSettings
    render_error("対象年と集計対象を選択肢から正しい形式で指定してください。", :unprocessable_content)
  rescue Cards::Data::RenderingError
    render_error("集計カードを描画できません。設定と元データを確認して再生成してください。", :unprocessable_content)
  rescue Cards::Memory::InvalidSettings
    render_error("活動を重複なく1〜3件と、その活動に添付された写真を正しい形式で選択してください。", :unprocessable_content)
  rescue Cards::Crop::Invalid
    render_error("画像の調整範囲が不正です。画像内の範囲と1.0〜3.0倍の倍率を指定してください。", :unprocessable_content)
  rescue ActionDispatch::Http::Parameters::ParseError
    render_error("画像の調整設定を正しいJSON形式で指定してください。", :bad_request)
  rescue ActionController::BadRequest, ArgumentError
    render_error("推しを重複なく1〜4人、正しい形式で選択してください。", :unprocessable_content)
  rescue ActiveRecord::RecordNotFound
    message = if settings && settings[:template] == "memory"
      "選択した活動・写真は利用できません。"
    elsif settings && settings.key?(:image_attachment_ids)
      "選択した推し・画像は利用できません。画像を選び直して再生成してください。"
    else
      "選択した推しは利用できません。"
    end
    render_error(message, :not_found)
  rescue Cards::Photo::ProfileRequired
    render_error("プロフィールを保存してから作成してください。", :unprocessable_content)
  rescue Cards::Photo::ImageDimensionsExceeded
    render_error("画像が大きすぎます。最大辺2560px・総画素数500万以下の画像を選んでください。", :unprocessable_content)
  rescue Cards::Photo::InvalidImage
    render_error("登録画像を読み取れません。未登録とは異なる状態です。画像を確認してください。", :unprocessable_content)
  rescue Cards::Photo::FontUnavailable
    render_error("描画用フォントを利用できません。", :service_unavailable)
  rescue SourceChanged
    render_error("元データが変更されました。もう一度プレビューを作成してください。", :conflict)
  rescue Cards::RenderGate::Busy
    response.headers["Retry-After"] = RETRY_AFTER.to_s
    render_error("カード生成が混み合っています。5秒後にもう一度お試しください。", :service_unavailable)
  end

  def download
    receipt = request.headers["X-Card-Receipt"].to_s
    return render_error("保存情報が不正です。", :unprocessable_content) if receipt.bytesize > 16.kilobytes
    payload = verifier.verified(receipt, purpose: PURPOSE)
    return render_error("保存情報が不正です。再生成してください。", :unprocessable_content) unless valid_payload?(payload)
    return render_error("この画像は保存できません。", :forbidden) unless payload["user_id"] == current_user.id && payload["auth_context"] == auth_context
    return render_error("プレビューの期限が切れました。再生成してください。", :gone) if Time.current.to_i >= payload["expires_at"]
    return render_error("画像のサイズが一致しません。", :unprocessable_content) unless request.content_length == payload["byte_size"]

    png = request.raw_post
    return render_error("確認した画像と一致しません。", :unprocessable_content) unless Digest::SHA256.hexdigest(png) == payload["png_sha256"]
    raise SourceChanged unless card_renderer(payload["settings"]).fingerprint == payload["source"]

    response.headers["X-PNG-SHA256"] = payload["png_sha256"]
    send_data png, type: "image/png", disposition: "attachment", filename: "oshilog-card.png"
  rescue ActiveRecord::RecordNotFound, Cards::Photo::ProfileRequired, Cards::Photo::InvalidImage,
    Cards::Crop::Invalid, Cards::Memory::InvalidSettings, Cards::Data::InvalidSettings,
    ActionController::BadRequest, ArgumentError, UnsupportedTemplate, SourceChanged
    render_error("元データまたは画像が変更されたか、取得できません。再生成してください。", :conflict)
  end

  private
    class SourceChanged < StandardError; end
    class UnsupportedTemplate < StandardError; end

    def private_response
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Vary"] = "Cookie"
      response.headers["X-Content-Type-Options"] = "nosniff"
      render_error("ログインしてください。", :unauthorized) if action_name != "new" && !user_signed_in?
    end

    def initial_user_oshi_id
      value = params[:user_oshi_id]
      return if value.blank?
      raise ActionController::BadRequest unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,18}\z/) && value.to_i <= 2**63 - 1

      @user_oshis.find { |record| record.id == value.to_i }&.id || raise(ActiveRecord::RecordNotFound)
    end

    def card_settings(input = params.require(:card))
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)
      template = input.key?(:template) ? input[:template] : "photo"
      raise UnsupportedTemplate unless %w[photo visual memories memory data].include?(template)
      if template == "data"
        return Cards::Data.settings(input.to_unsafe_h.except("template")).merge(template: "data")
      end
      if %w[memories memory].include?(template)
        return Cards::Memory.settings(input.to_unsafe_h.except("template")).merge(template: "memory")
      end
      raise ArgumentError unless (input.keys - %w[template user_oshi_ids image_user_oshi_ids image_attachment_ids show_introduction crops collage_image_attachment_ids collage_crops]).empty?
      # Rails removes nulls from arrays. Reject them before that normalization
      # can turn an invalid array into a different, apparently valid frame order.
      if request.media_type == "application/json" && request.raw_post.present?
        original = JSON.parse(request.raw_post)
        if original.is_a?(Hash) && original["card"].is_a?(Hash)
          raise ArgumentError if %w[user_oshi_ids image_user_oshi_ids image_attachment_ids].any? { |key| original["card"][key].is_a?(Array) && original["card"][key].include?(nil) }
          original_crops = original["card"]["crops"]
          raise Cards::Crop::Invalid if original_crops.is_a?(Array) && original_crops.include?(nil)
        end
      end
      ids = input[:user_oshi_ids]
      raise ArgumentError unless ids.is_a?(Array) && ids.length.between?(1, 4) && ids.uniq.length == ids.length
      raise ArgumentError unless ids.all? { |id| id.is_a?(String) && id.match?(/\A[1-9][0-9]{0,18}\z/) && id.to_i <= 2**63 - 1 }
      images = input[:image_user_oshi_ids]
      raise ArgumentError unless images.is_a?(Array) && images.length == ids.length
      # Rails removes null entries from parameter arrays. An empty string keeps
      # disabled frames in place instead of shifting the following image source.
      raise ArgumentError unless images.all? { |id| id == "" || ids.include?(id) }
      raise ArgumentError unless [ true, false ].include?(input[:show_introduction])
      settings = { user_oshi_ids: ids, image_user_oshi_ids: images, show_introduction: input[:show_introduction] }
      if input.key?(:image_attachment_ids)
        attachments = input[:image_attachment_ids]
        Cards::Photo.validate_image_ids!(images, attachments)
        settings[:image_attachment_ids] = attachments
      end
      if input.key?(:crops)
        crops = input[:crops]
        raise Cards::Crop::Invalid unless crops.is_a?(Array) && crops.length == ids.length

        settings[:crops] = crops.map do |crop|
          raise Cards::Crop::Invalid unless crop.is_a?(ActionController::Parameters)

          Cards::Crop.normalize(crop.to_unsafe_h)
        end
      end
      if input.key?(:collage_image_attachment_ids) || input.key?(:collage_crops)
        raise ArgumentError unless ids.length == 1 && input.key?(:collage_image_attachment_ids) && input.key?(:collage_crops)
        attachments = input[:collage_image_attachment_ids]
        collage_crops = input[:collage_crops]
        raise ArgumentError unless attachments.is_a?(Array) && attachments.length == 3
        raise Cards::Crop::Invalid unless collage_crops.is_a?(Array) && collage_crops.length == 3
        settings[:collage_image_attachment_ids] = attachments
        settings[:collage_crops] = collage_crops.map do |crop|
          raise Cards::Crop::Invalid unless crop.is_a?(ActionController::Parameters)
          Cards::Crop.normalize(crop.to_unsafe_h)
        end
      end
      settings
    end

    def card_renderer(settings)
      settings = card_settings(ActionController::Parameters.new(settings))
      service = case settings.delete(:template)
      when "memory" then Cards::Memory
      when "data" then Cards::Data
      else Cards::Photo
      end
      service.new(user: current_user, **settings)
    end

    def valid_payload?(payload)
      payload.is_a?(Hash) && payload["user_id"].is_a?(Integer) && payload["auth_context"].is_a?(String) &&
        payload["settings"].is_a?(Hash) && payload["source"].is_a?(String) &&
        payload["png_sha256"].is_a?(String) && payload["byte_size"].is_a?(Integer) && payload["byte_size"].positive? &&
        payload["expires_at"].is_a?(Integer)
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def auth_context
      Digest::SHA256.hexdigest(request.session.id.to_s)
    end

    def render_error(message, status)
      render json: { error: message }, status: status
    end

    def render_bounded_json(payload)
      json = JSON.generate(payload)
      return render body: json, content_type: "application/json" if json.bytesize <= MAX_JSON_BYTES

      render_error("応答量の上限を超えました。関連情報をより小さい単位で読み込んでください。", :unprocessable_content)
    end
end
