require "rails_helper"
require "tmpdir"
require_relative "../support/image_attachments"
require_relative "../support/card_images"

RSpec.describe "Photo cards", type: :request do
  include ImageAttachments
  include CardImages
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:profile) { create(:profile, user: user) }
  let(:user_oshi) { create(:user_oshi, user: user) }

  around do |example|
    previous_registry = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshilog-card-spec-") do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      ActiveStorage::Blob.services = previous_registry
      ActiveStorage::Blob.service = previous_service
    end
  end

  def login(account = user)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def generate_card(ids = user_oshi.id, **settings)
    ids = Array(ids).map(&:to_s)
    post card_path, params: { card: { user_oshi_ids: ids, image_user_oshi_ids: ids,
      show_introduction: true }.merge(settings) }, as: :json
  end

  def attach_color(record, color)
    bytes = Vips::Image.black(8, 10, bands: 3).new_from_image(color).copy(interpretation: :srgb)
      .write_to_buffer(".png")
    record.representative_image.attach(io: StringIO.new(bytes), filename: "color.png", content_type: "image/png")
  end

  def save_card(png, receipt)
    post download_card_path, params: png, headers: { "CONTENT_TYPE" => "image/png", "X-Card-Receipt" => receipt }
  end

  it "requires login for the page, generation and download" do
    get new_card_path
    expect(response).to redirect_to(new_user_session_path)
    generate_card
    expect(response).to have_http_status(:unauthorized)
    save_card("png", "receipt")
    expect(response).to have_http_status(:unauthorized)
  end

  it "requires an explicitly saved Profile" do
    login
    get new_card_path
    expect(response).to redirect_to(edit_profile_path)
    expect(user.reload.profile).to be_nil
    generate_card
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "shows only this user's registered oshis and disables Turbo snapshots" do
    profile
    user_oshi
    foreign = create(:user_oshi)
    login
    get new_card_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(user_oshi.oshi.name, 'name="turbo-cache-control" content="no-cache"')
    expect(response.body).not_to include(foreign.oshi.name)
  end

  it "shows all template choices with photo selected and all settings available without persisting settings" do
    profile
    user_oshi
    login
    original = profile.reload.attributes
    expect { get new_card_path }.not_to change(Profile, :count)
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    radios = document.css("input[type='radio'][name='template']")
    expect(radios.map { |input| input["value"] }).to eq(%w[photo memories data])
    expect(radios.select { |input| input.key?("checked") }.map { |input| input["value"] }).to eq([ "photo" ])
    expect(document.at_css("#card-settings-photo").key?("hidden")).to be(false)
    data = document.at_css("#card-settings-data")
    expect(data.key?("hidden")).to be(true)
    expect(data.text).not_to include("PNG生成は未実装")
    expect(data.at_css("button[type='submit']").key?("disabled")).to be(true)
    expect(data.at_css("input[name='show_introduction']")).to be_nil
    expect(data.at_css("select#card-data-year")).to be_present
    expect(data.at_css("select#card-data-oshi")).to be_present
    memory = document.at_css("#card-settings-memories")
    expect(memory.key?("hidden")).to be(true)
    expect(memory.text).to include("活動を1〜3件")
    expect(memory.text).not_to include("PNG生成は未実装")
    expect(memory.at_css("input[name='show_introduction']")).to be_nil
    expect(memory.at_css("button[type='submit']").key?("disabled")).to be(true)
    expect(profile.reload.attributes).to eq(original)
  end

  it "shows the template selector with no registered oshis without reading activity or subscription data" do
    profile
    login
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
    get new_card_path
    ActiveSupport::Notifications.unsubscribe(subscription)
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.css("input[name='template']").size).to eq(3)
    expect(document.at_css("[data-photo-card-target='generateButton']").key?("disabled")).to be(true)
    expect(document.at_css("a[href='#{new_oshi_path}']")).to be_present
    expect(queries.join).not_to match(/\b(?:activities|activity_oshis|subscriptions)\b/i)
    expect(user.user_oshis).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "offers an automatic template suggestion without saving profile or card settings" do
    profile
    record = user_oshi
    login

    original = profile.reload.attributes
    expect { get new_card_path }.not_to change(Profile, :count)
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    builder = document.at_css("[data-controller='photo-card']")
    payload = JSON.parse(builder["data-photo-card-recommendation-value"])
    expect(payload).to include("template" => "photo", "user_oshi_ids" => [ record.id.to_s ])
    expect(document.text).to include("おまかせで選ぶ（試験版）")
    expect(profile.reload.attributes).to eq(original)
  end

  it "accepts an explicit photo template and preserves the existing preview download contract" do
    profile
    login
    generate_card(template: "photo")
    expect(response).to have_http_status(:ok)
    png = response.body.dup
    receipt = response.headers.fetch("X-Card-Receipt")
    expect(response.media_type).to eq("image/png")
    save_card(png, receipt)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png)
  end

  [ "unknown", nil, [ "photo" ], { name: "photo" } ].each do |template|
    it "rejects unsupported template #{template.inspect} without rendering or persisting" do
      profile
      login
      expect(Cards::Photo).not_to receive(:new)
      counts = [ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      generate_card(template: template)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]).to include("利用できません")
      expect(response.headers["X-Card-Receipt"]).to be_nil
      expect([ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end
  end

  context "with crop settings" do
    before do
      profile
      login
    end

    it "signs crops, preserves originals, reads no activity data, and downloads identical bytes" do
      bytes = attach_coordinates(user_oshi)
      blob = user_oshi.representative_image.blob
      original = blob.reload.attributes
      crop = { x: 0.25, y: 0.35, zoom: 3 }
      queries = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
      counts = [ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      generate_card(crops: [ crop ])
      ActiveSupport::Notifications.unsubscribe(subscription)
      expect(response).to have_http_status(:ok)
      png = response.body.dup
      receipt = response.headers.fetch("X-Card-Receipt")
      expect(receipt.bytesize).to be < 16.kilobytes
      payload = Rails.application.message_verifier(CardsController::PURPOSE).verified(receipt, purpose: CardsController::PURPOSE)
      expect(payload.fetch("settings").fetch("crops")).to eq([ crop.stringify_keys ])
      expect(queries.join).not_to match(/\b(?:activities|activity_oshis|subscriptions)\b/i)
      save_card(png, receipt)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(png)
      expect([ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      expect(blob.reload.attributes).to eq(original)
      expect(blob.download).to eq(bytes)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    it "rejects a crop-altered receipt, a modified PNG and an original replaced after preview" do
      attach_coordinates(user_oshi)
      generate_card(crops: [ { x: 0.5, y: 0.5, zoom: 3 } ])
      expect(response).to have_http_status(:ok)
      png = response.body.dup
      receipt = response.headers.fetch("X-Card-Receipt")
      verifier = Rails.application.message_verifier(CardsController::PURPOSE)
      payload = verifier.verified(receipt, purpose: CardsController::PURPOSE)
      payload.fetch("settings").fetch("crops").first["zoom"] = 1
      altered_body = verifier.generate(payload, purpose: CardsController::PURPOSE).split("--").first
      tampered = "#{altered_body}--#{receipt.split('--').last}"
      save_card(png, tampered)
      expect(response).to have_http_status(:unprocessable_content)
      save_card(png.sub("PNG", "BAD"), receipt)
      expect(response).to have_http_status(:unprocessable_content)
      user_oshi.representative_image.attach(image_upload("image.jpg"))
      save_card(png, receipt)
      expect(response).to have_http_status(:conflict)
    end

    it "bounds a four-frame receipt even when the same image is cropped four different ways" do
      records = Array.new(4) { create(:user_oshi, user: user) }
      attach_coordinates(records.first)
      crops = [ 0.2, 0.4, 0.6, 0.8 ].map { |x| { x: x, y: 0.5, zoom: 3 } }
      generate_card(records.map(&:id), image_user_oshi_ids: [ records.first.id.to_s ] * 4, crops: crops)
      expect(response).to have_http_status(:ok)
      png = response.body.dup
      receipt = response.headers.fetch("X-Card-Receipt")
      expect(receipt.bytesize).to be < 16.kilobytes
      save_card(png, receipt)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(png)
    end

    [ nil, [], {}, "crop", [ nil ], [ true ], [ [] ], [ {} ],
      [ { x: "0.5", y: 0.5, zoom: 1 } ], [ { x: 0.5, y: false, zoom: 1 } ],
      [ { x: 0.5, y: 0.5, zoom: "1" } ], [ { x: -0.1, y: 0.5, zoom: 1 } ],
      [ { x: 0.5, y: 1.1, zoom: 1 } ], [ { x: 0.5, y: 0.5, zoom: 0.99 } ],
      [ { x: 0.5, y: 0.5, zoom: 3.01 } ], [ { x: 0.5, y: 0.5, zoom: 1, url: "foreign" } ],
      [ { x: 0.5, y: 0.5, zoom: 1 }, { x: 0.5, y: 0.5, zoom: 1 } ] ].each do |crops|
      it "rejects malformed or extra crop settings #{crops.inspect}" do
        generate_card(crops: crops)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.media_type).to eq("application/json")
        expect(response.parsed_body["error"]).to include("調整範囲が不正")
        expect(response.headers["X-Card-Receipt"]).to be_nil
      end
    end

    it "rejects syntactically non-finite JSON coordinates" do
      %w[NaN Infinity -Infinity].each do |value|
        post card_path, params: %Q({"card":{"crops":[{"x":#{value},"y":0.5,"zoom":1}]}}), headers: { "CONTENT_TYPE" => "application/json" }
        expect(response).to have_http_status(:bad_request)
        expect(response.headers["X-Card-Receipt"]).to be_nil
      end
    end

    it "rejects an in-range centre whose visible window extends outside the image" do
      attach_coordinates(user_oshi)
      generate_card(crops: [ { x: 0.1, y: 0.5, zoom: 1 } ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("調整範囲が不正")
    end

    it "preserves missing and switched-off image slots with default crops only" do
      generate_card(crops: [ Cards::Crop::DEFAULT ])
      expect(response).to have_http_status(:ok)
      generate_card(crops: [ { x: 0.5, y: 0.5, zoom: 2 } ])
      expect(response).to have_http_status(:unprocessable_content)
      attach_coordinates(user_oshi)
      user_oshi.representative_image.blob.service.delete(user_oshi.representative_image.blob.key)
      generate_card(crops: [ Cards::Crop::DEFAULT ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("未登録とは異なる")
      generate_card(image_user_oshi_ids: [ "" ], crops: [ Cards::Crop::DEFAULT ])
      expect(response).to have_http_status(:ok)
    end

    it "still rejects another user's source when valid crop settings are supplied" do
      foreign = create(:user_oshi)
      attach_coordinates(foreign)
      generate_card(foreign.id, crops: [ Cards::Crop::DEFAULT ])
      expect(response).to have_http_status(:not_found)
    end
  end

  it "generates a real PNG, reads no Activity and does not persist card data" do
    profile
    user_oshi.representative_image.attach(image_upload)
    login
    original_profile = profile.reload.attributes
    original_metadata = user_oshi.representative_image.blob.reload.attributes
    original_bytes = user_oshi.representative_image.download
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
    counts = [ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    generate_card
    ActiveSupport::Notifications.unsubscribe(subscription)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    image = Vips::Image.new_from_buffer(response.body, "")
    expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
    expect(queries.join).not_to match(/\b(?:activities|activity_oshis|subscriptions)\b/i)
    expect([ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    expect(profile.reload.attributes).to eq(original_profile)
    expect(user_oshi.representative_image.blob.reload.attributes).to eq(original_metadata)
    expect(user_oshi.representative_image.download).to eq(original_bytes)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "generates when no image is registered, while preserving the Oshi name" do
    profile
    login
    generate_card
    expect(response).to have_http_status(:ok)
    image = Vips::Image.new_from_buffer(response.body, "")
    expect(image.width).to eq(1600)
    # Inspect the broad text area, without matching individual glyphs or a stored bitmap.
    name_area = image.crop(568, 176, 984, 132)
    expect(name_area.min).to be < 255
    user_oshi.oshi.update!(name: "名前を変更した推し")
    generate_card
    expect(response).to have_http_status(:ok)
    updated = Vips::Image.new_from_buffer(response.body, "")
    expect(updated.crop(568, 176, 984, 132).write_to_buffer(".png"))
      .not_to eq(name_area.write_to_buffer(".png"))
  end

  it "omits the introduction from the PNG when show_introduction is false without modifying saved text" do
    profile.update!(introduction: "ライブと舞台を楽しんでいます。")
    login
    generate_card(show_introduction: true)
    expect(response).to have_http_status(:ok)
    shown = Vips::Image.new_from_buffer(response.body, "")
    generate_card(show_introduction: false)
    expect(response).to have_http_status(:ok)
    hidden = Vips::Image.new_from_buffer(response.body, "")
    # The lower card area contains only the optional introduction, below the photo and name.
    expect(shown.crop(0, 800, shown.width, shown.height - 800).min).to be < 255
    expect(hidden.crop(0, 800, hidden.width, hidden.height - 800).min).to eq(255)
    expect(profile.reload.introduction).to eq("ライブと舞台を楽しんでいます。")
  end

  it "returns JSON 503 without a preview receipt when the rendering font is unavailable" do
    profile
    login
    allow(File).to receive(:file?).and_call_original
    allow(File).to receive(:file?).with(Cards::Photo::FONT_FILE).and_return(false)
    generate_card
    expect(response).to have_http_status(:service_unavailable)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("error" => "描画用フォントを利用できません。")
    expect(response.headers["X-Card-Receipt"]).to be_nil
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
  end

  %w[image.jpg image.webp].each do |filename|
    it "generates from a registered static #{File.extname(filename)} image" do
      profile
      user_oshi.representative_image.attach(image_upload(filename))
      login
      generate_card
      expect(response).to have_http_status(:ok)
      image = Vips::Image.new_from_buffer(response.body, "")
      expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
    end
  end

  it "rejects a MIME type that disagrees with the actual image format" do
    profile
    blob = ActiveStorage::Blob.create_and_upload!(**image_upload,
      content_type: "image/jpeg", identify: false)
    user_oshi.representative_image.attach(blob)
    login
    generate_card
    expect(response).to have_http_status(:unprocessable_content)
    expect(user_oshi.reload.representative_image.blob.id).to eq(blob.id)
  end

  it "accepts rejected or ended registered oshis without Activity" do
    profile
    user_oshi.update!(ended_period: "2024")
    user_oshi.oshi.update!(status: :rejected)
    login
    generate_card
    expect(response).to have_http_status(:ok)
  end

  it "rejects a different user's UserOshi" do
    profile
    login
    generate_card(create(:user_oshi).id)
    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("application/json")
  end

  it "rejects a mixed selection containing another user's UserOshi even with its image off" do
    profile
    foreign = create(:user_oshi)
    login
    generate_card([ user_oshi.id, foreign.id ], image_user_oshi_ids: [ user_oshi.id.to_s, "" ])
    expect(response).to have_http_status(:not_found)
    expect(response.headers["X-Card-Receipt"]).to be_nil
  end

  it "rejects scalar, empty, duplicate, excessive and malformed selection arrays" do
    profile
    login
    id = user_oshi.id.to_s
    [ id, [], [ id, id ], [ id ] * 5, [ "1abc" ], [ "0" ], [ "9" * 20 ], [ user_oshi.id ] ].each do |ids|
      post card_path, params: { card: { user_oshi_ids: ids, image_user_oshi_ids: [ id ], show_introduction: true } }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "reports missing originals instead of returning a placeholder PNG" do
    profile
    user_oshi.representative_image.attach(image_upload)
    user_oshi.representative_image.blob.service.delete(user_oshi.representative_image.blob.key)
    login
    generate_card
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("未登録とは異なる")
  end

  it "rejects changed image bytes and leaves the attachment intact" do
    profile
    user_oshi.representative_image.attach(image_upload)
    blob = user_oshi.representative_image.blob
    File.binwrite(blob.service.path_for(blob.key), "broken")
    login
    generate_card
    expect(response).to have_http_status(:unprocessable_content)
    expect(user_oshi.reload.representative_image.blob.id).to eq(blob.id)
  end

  it "does not read an image explicitly switched off" do
    profile
    user_oshi.representative_image.attach(image_upload)
    user_oshi.representative_image.blob.service.delete(user_oshi.representative_image.blob.key)
    login
    generate_card(user_oshi.id, image_user_oshi_ids: [ "" ])
    expect(response).to have_http_status(:ok)
  end

  it "returns the identical preview bytes on an explicit download" do
    profile
    login
    generate_card
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    save_card(png, receipt)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png)
    expect(response.headers["Content-Disposition"]).to include("attachment", "oshilog-card.png")
  end

  it "rejects modified PNG bytes or a forged receipt" do
    profile
    login
    generate_card
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    modified = png.dup
    modified.setbyte(modified.length - 1, modified.getbyte(modified.length - 1) ^ 1)
    save_card(modified, receipt)
    expect(response).to have_http_status(:unprocessable_content)
    save_card(png, "forged")
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects source changes after preview without re-rendering" do
    profile
    login
    generate_card
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    user_oshi.oshi.update!(name: "変更後")
    save_card(png, receipt)
    expect(response).to have_http_status(:conflict)
  end

  it "rejects Profile changes made while the image is being generated" do
    profile
    login
    allow_any_instance_of(Cards::Photo).to receive(:render).and_wrap_original do |render|
      png = render.call
      profile.update!(display_name: "生成中に変更")
      png
    end
    generate_card
    expect(response).to have_http_status(:conflict)
    expect(response.headers["X-Card-Receipt"]).to be_nil
  end

  it "rejects expired previews and receipts reused by another account" do
    profile
    login
    generate_card
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    travel 15.minutes do
      save_card(png, receipt)
      expect(response).to have_http_status(:gone)
    end
    delete destroy_user_session_path
    login(create(:user))
    save_card(png, receipt)
    expect(response).to have_http_status(:forbidden)
  end

  it "renders saved markup as literal text and never modifies a long introduction" do
    profile.update!(display_name: "<span>&表示名", introduction: "か\u3099👩🏽‍💻" * 400)
    login
    original = profile.introduction
    generate_card
    expect(response).to have_http_status(:ok)
    image = Vips::Image.new_from_buffer(response.body, "")
    name_area = image.crop(48, 48, 1200, 64)
    expect(name_area.min).to be < 255
    expect(image.crop(0, 800, image.width, image.height - 800).min).to be < 255
    profile.update!(display_name: "変更した表示名")
    generate_card
    expect(response).to have_http_status(:ok)
    updated = Vips::Image.new_from_buffer(response.body, "")
    expect(updated.crop(48, 48, 1200, 64).write_to_buffer(".png"))
      .not_to eq(name_area.write_to_buffer(".png"))
    expect(profile.reload.introduction).to eq(original)
  end

  it "rejects a receipt after logout and login as the same user" do
    profile
    login
    generate_card
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    delete destroy_user_session_path
    login
    save_card(png, receipt)
    expect(response).to have_http_status(:forbidden)
  end

  it "requires a valid CSRF token when forgery protection is enabled" do
    profile
    user_oshi
    login
    previous = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    generate_card
    expect(response).to have_http_status(:unprocessable_content)
    get new_card_path
    token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]
    post card_path, params: { card: { user_oshi_ids: [ user_oshi.id.to_s ], image_user_oshi_ids: [ user_oshi.id.to_s ],
      show_introduction: true } }, as: :json, headers: { "X-CSRF-Token" => token }
    expect(response).to have_http_status(:ok)
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    post download_card_path, params: png, headers: { "CONTENT_TYPE" => "image/png",
      "X-Card-Receipt" => receipt, "X-CSRF-Token" => token }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png)
  ensure
    ApplicationController.allow_forgery_protection = previous
  end

  {
    1 => { xs: [ 48 ], width: 496, height: 620 },
    2 => { xs: [ 372, 812 ], width: 416, height: 520 },
    3 => { xs: [ 152, 592, 1032 ], width: 416, height: 520 },
    4 => { xs: [ 72, 440, 808, 1176 ], width: 352, height: 440 }
  }.each do |count, layout|
    it "renders #{count} ordered photo frames at the requested dimensions and positions" do
      profile
      colors = [ [ 255, 0, 0 ], [ 0, 255, 0 ], [ 0, 0, 255 ], [ 255, 255, 0 ] ].take(count)
      records = Array.new(count) { create(:user_oshi, user: user) }
      records.zip(colors).each { |record, color| attach_color(record, color) }
      login
      generate_card(records.reverse.map(&:id))
      expect(response).to have_http_status(:ok)
      image = Vips::Image.new_from_buffer(response.body, "")
      expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
      layout[:xs].zip(colors.reverse).each do |x, color|
        expect(image.getpoint(x, 176).take(3)).to eq(color)
        expect(image.getpoint(x + layout[:width] - 1, 176 + layout[:height] - 1).take(3)).to eq(color)
        expect(image.getpoint(x - 1, 176).take(3)).to eq([ 255, 255, 255 ])
        expect(image.getpoint(x + layout[:width], 176).take(3)).to eq([ 255, 255, 255 ])
        expect(image.getpoint(x, 176 + layout[:height]).take(3)).to eq([ 255, 255, 255 ])
      end
    end
  end

  it "shares a selected representative image across frames while preserving their names" do
    profile
    records = Array.new(2) { create(:user_oshi, user: user) }
    attach_color(records[0], [ 255, 0, 0 ])
    attach_color(records[1], [ 0, 255, 0 ])
    login
    generate_card(records.map(&:id))
    original = Vips::Image.new_from_buffer(response.body, "")
    generate_card(records.map(&:id), image_user_oshi_ids: [ records[1].id.to_s ] * 2)
    expect(response).to have_http_status(:ok)
    shared = Vips::Image.new_from_buffer(response.body, "")
    [ 372, 812 ].each do |x|
      expect(shared.getpoint(x, 176).take(3)).to eq([ 0, 255, 0 ])
      expect(shared.crop(x, 704, 416, 80).min).to be < 255
      expect(shared.crop(x, 704, 416, 80).write_to_buffer(".png"))
        .to eq(original.crop(x, 704, 416, 80).write_to_buffer(".png"))
    end
  end

  it "rejects image sources outside the selected set, including another user's image" do
    profile
    unselected = create(:user_oshi, user: user)
    foreign = create(:user_oshi)
    login
    [ unselected.id.to_s, foreign.id.to_s ].each do |source|
      generate_card(user_oshi.id, image_user_oshi_ids: [ source ])
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "rejects malformed or incomplete per-frame image settings" do
    profile
    login
    [ nil, [], [ nil, nil ], [ false ], [ user_oshi.id ] ].each do |images|
      generate_card(user_oshi.id, image_user_oshi_ids: images)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "keeps missing and switched-off image slots while reading only the enabled source" do
    profile
    records = Array.new(3) { create(:user_oshi, user: user) }
    attach_color(records[1], [ 0, 255, 0 ])
    records[1].representative_image.blob.service.delete(records[1].representative_image.blob.key)
    attach_color(records[2], [ 0, 0, 255 ])
    login
    generate_card(records.map(&:id), image_user_oshi_ids: [ records[0].id.to_s, "", records[2].id.to_s ])
    expect(response).to have_http_status(:ok)
    image = Vips::Image.new_from_buffer(response.body, "")
    [ 152, 592 ].each { |x| expect(image.getpoint(x, 176).take(3)).to eq([ 240, 243, 246 ]) }
    expect(image.getpoint(1032, 176).take(3)).to eq([ 0, 0, 255 ])
  end

  it "refuses the whole card if any enabled original cannot be retrieved" do
    profile
    records = Array.new(2) { create(:user_oshi, user: user) }
    records.each { |record| record.representative_image.attach(image_upload) }
    records.last.representative_image.blob.service.delete(records.last.representative_image.blob.key)
    login
    generate_card(records.map(&:id))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.media_type).to eq("application/json")
    expect(response.headers["X-Card-Receipt"]).to be_nil
  end

  it "generates a four-person card with placeholders when no images are registered" do
    profile
    records = Array.new(4) { create(:user_oshi, user: user) }
    login
    generate_card(records.map(&:id))
    expect(response).to have_http_status(:ok)
    image = Vips::Image.new_from_buffer(response.body, "")
    [ 72, 440, 808, 1176 ].each do |x|
      expect(image.getpoint(x, 176).take(3)).to eq([ 240, 243, 246 ])
    end
  end

  it "rechecks all selected names and used originals before returning the identical multi-person PNG" do
    profile
    records = Array.new(4) { create(:user_oshi, user: user) }
    records.each { |record| record.representative_image.attach(image_upload) }
    login
    generate_card(records.map(&:id))
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    save_card(png, receipt)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png)
    records.last.oshi.update!(name: "最後の推しの変更")
    save_card(png, receipt)
    expect(response).to have_http_status(:conflict)
    generate_card(records.map(&:id))
    png = response.body.dup
    receipt = response.headers["X-Card-Receipt"]
    records.last.representative_image.attach(image_upload("image.jpg"))
    save_card(png, receipt)
    expect(response).to have_http_status(:conflict)
  end

  it "reads no Activity or year data and does not persist or modify sources for four people" do
    profile
    records = Array.new(4) { create(:user_oshi, user: user) }
    records.each { |record| record.representative_image.attach(image_upload) }
    before = records.map { |record| [ record.reload.attributes, record.representative_image.blob.reload.attributes,
      record.representative_image.download ] }
    original_profile = profile.reload.attributes
    counts = [ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    queries = []
    login
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
    generate_card(records.map(&:id))
    ActiveSupport::Notifications.unsubscribe(subscription)
    expect(response).to have_http_status(:ok)
    expect(queries.join).not_to match(/\b(?:activities|activity_oshis|subscriptions)\b/i)
    expect([ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    expect(profile.reload.attributes).to eq(original_profile)
    expect(records.map { |record| [ record.reload.attributes, record.representative_image.blob.reload.attributes,
      record.representative_image.download ] }).to eq(before)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  [ :outside, :hidden, :absent ].each do |image_state|
    it "revalidates the actual crop window from a signed receipt for #{image_state} images" do
      profile
      attach_coordinates(user_oshi) unless image_state == :absent
      login
      images = image_state == :hidden ? [ "" ] : [ user_oshi.id.to_s ]
      generate_card(image_user_oshi_ids: images, crops: [ Cards::Crop::DEFAULT ])
      expect(response).to have_http_status(:ok)
      png = response.body.dup
      verifier = Rails.application.message_verifier(CardsController::PURPOSE)
      payload = verifier.verified(response.headers.fetch("X-Card-Receipt"), purpose: CardsController::PURPOSE)
      payload["settings"]["crops"] = [ image_state == :outside ? { "x" => 0, "y" => 0.5, "zoom" => 1 } : { "x" => 0.5, "y" => 0.5, "zoom" => 2 } ]
      receipt = verifier.generate(payload, purpose: CardsController::PURPOSE)
      expect_any_instance_of(Cards::Photo).not_to receive(:render)
      save_card(png, receipt)
      expect(response).to have_http_status(:conflict)
      expect(response.media_type).to eq("application/json")
    end
  end
end
