require "rails_helper"
require "tmpdir"
require_relative "../support/card_images"

RSpec.describe "Memory cards", type: :request do
  include CardImages
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { create(:user) }
  let(:activity) { create(:activity, user: user, occurred_on: Date.current) }

  around do |example|
    registry = ActiveStorage::Blob.services
    service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshilog-memory-request-") do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      ActiveStorage::Blob.services = registry
      ActiveStorage::Blob.service = service
    end
  end

  before do
    create(:profile, user: user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def generate(records = [ activity ], **options)
    post card_path, params: { card: { template: "memory", activity_ids: records.map { |record| record.id.to_s },
      image_attachment_ids: records.map { |record| record.images_attachments.order(:id).first&.id.to_s },
      crops: records.map { Cards::Crop::DEFAULT } }.merge(options) }, as: :json
  end

  def save(png, receipt)
    post download_card_path, params: png, headers: { "CONTENT_TYPE" => "image/png", "X-Card-Receipt" => receipt }
  end

  def attach_photo(record = activity)
    bytes = coordinate_image
    record.images.attach(io: StringIO.new(bytes), filename: "coordinates.png", content_type: "image/png")
    bytes
  end

  it "loads only eligible owned candidates in date, creation and ID order without exposing private fields" do
    old = create(:activity, user: user, occurred_on: Date.current - 1)
    timestamp = Time.current.change(usec: 0)
    first = create(:activity, user: user, occurred_on: Date.current, created_at: timestamp)
    second = create(:activity, user: user, occurred_on: Date.current, created_at: timestamp)
    newest = create(:activity, user: user, occurred_on: Date.current, created_at: timestamp + 1)
    future = create(:activity, user: user, occurred_on: Date.current + 1)
    other = create(:activity)
    attach_photo(newest)
    attach_photo(newest)
    get memories_card_path
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    candidates = response.parsed_body.fetch("activities")
    expect(candidates.map { |item| item["id"] }).to eq([ newest, second, first, old ].map { |record| record.id.to_s })
    expect(candidates.map { |item| item["id"] }).not_to include(future.id.to_s, other.id.to_s)
    expect(candidates.first.keys).to match_array(%w[id date title category oshis images])
    images = candidates.first.fetch("images")
    expect(images.map { |image| image["id"] }).to eq(newest.images_attachments.order(:id).pluck(:id).map(&:to_s))
    expect(images.first["url"]).to eq(protected_image_path(newest.images_attachments.order(:id).first))
    get images.first["url"]
    expect(response).to have_http_status(:ok)
    delete destroy_user_session_path
    get memories_card_path
    expect(response).to have_http_status(:unauthorized)
    get images.first["url"]
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns at most fifty candidates per keyset page and reaches every older eligible activity" do
    timestamp = Time.current.change(usec: 0)
    records = Array.new(52) { create(:activity, user: user, occurred_on: Date.current, created_at: timestamp) }
    create(:activity, user: user, occurred_on: Date.current + 1, created_at: timestamp + 1)
    create(:activity, occurred_on: Date.current, created_at: timestamp + 1)

    get memories_card_path
    expect(response).to have_http_status(:ok)
    first = response.parsed_body
    expect(first.fetch("activities").map { |item| item.fetch("id") }).to eq(records.reverse.first(50).map { |record| record.id.to_s })
    expect(first).to include("has_more" => true)
    expect(first.fetch("next_cursor")).to be_present

    create(:activity, user: user, occurred_on: Date.current, created_at: timestamp + 2)
    get memories_card_path, params: { cursor: first.fetch("next_cursor") }
    second = response.parsed_body
    expect(second.fetch("activities").map { |item| item.fetch("id") }).to eq(records.first(2).reverse.map { |record| record.id.to_s })
    expect(second).to include("has_more" => false, "next_cursor" => nil)
  end

  it "rejects malformed and activity-list cursors" do
    get memories_card_path, params: { cursor: "invalid" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("ページ情報が正しくありません")

    activity = create(:activity, user: user, occurred_on: Date.current)
    cursor = Activities::KeysetPage.call(scope: user.activities, cursor: nil, direction: "older", purpose: "index").older_cursor
    expect(activity).to be_present
    get memories_card_path, params: { cursor: cursor }
    expect(response).to have_http_status(:bad_request)
  end

  [ 1, 2, 3 ].each do |count|
    it "generates #{count} activities and downloads exactly the signed PNG without DB writes" do
      records = Array.new(count) { create(:activity, user: user, occurred_on: Date.current) }
      originals = records.map { |record| record.reload.attributes }
      counts = [ Profile.count, Activity.count, ActivityOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      generate(records)
      expect(response).to have_http_status(:ok)
      png = response.body.dup
      receipt = response.headers.fetch("X-Card-Receipt")
      image = Vips::Image.new_from_buffer(png, "")
      expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
      expect(receipt.bytesize).to be < 16.kilobytes
      save(png, receipt)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(png)
      expect(response.headers["X-PNG-SHA256"]).to eq(Digest::SHA256.hexdigest(png))
      expect(records.map { |record| record.reload.attributes }).to eq(originals)
      expect([ Profile.count, Activity.count, ActivityOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end
  end

  it "accepts the memories compatibility name and the visual alias while retaining legacy photo calls" do
    generate(template: "memories")
    expect(response).to have_http_status(:ok)
    record = create(:user_oshi, user: user)
    [ "visual", "photo", :omitted ].each do |template|
      settings = { user_oshi_ids: [ record.id.to_s ], image_user_oshi_ids: [ "" ], show_introduction: false }
      settings[:template] = template unless template == :omitted
      post card_path, params: { card: settings }, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  it "signs ordered activity IDs, image IDs and crops, leaves originals unchanged and rejects tampering" do
    bytes = attach_photo
    blob = activity.images.first.blob
    metadata = blob.reload.attributes
    attachment = activity.images.first.reload.attributes
    crop = { x: 0.3, y: 0.6, zoom: 3 }
    generate(crops: [ crop ])
    expect(response).to have_http_status(:ok)
    png = response.body.dup
    receipt = response.headers.fetch("X-Card-Receipt")
    verifier = Rails.application.message_verifier(CardsController::PURPOSE)
    payload = verifier.verified(receipt, purpose: CardsController::PURPOSE)
    expect(payload.fetch("settings")).to eq("template" => "memory", "activity_ids" => [ activity.id.to_s ],
      "image_attachment_ids" => [ attachment["id"].to_s ], "crops" => [ crop.stringify_keys ])
    save(png, receipt)
    expect(response.body).to eq(png)
    expect(blob.reload.attributes).to eq(metadata)
    expect(activity.images.first.reload.attributes).to eq(attachment)
    expect(blob.download).to eq(bytes)
    payload["settings"]["crops"][0]["zoom"] = 1
    modified = verifier.generate(payload, purpose: CardsController::PURPOSE).split("--").first
    save(png, "#{modified}--#{receipt.split('--').last}")
    expect(response).to have_http_status(:unprocessable_content)
    save(png + "modified", receipt)
    expect(response).to have_http_status(:unprocessable_content)
    other = create(:user)
    delete destroy_user_session_path
    post user_session_path, params: { user: { email: other.email, password: "password123" } }
    save(png, receipt)
    expect(response).to have_http_status(:forbidden)
  end

  [ :title, :occurred_on, :activity_type, :profile, :oshi_name, :add_link, :remove_link, :replace_image, :add_image, :purge_image, :bytes, :delete ].each do |change|
    it "refuses download after source change #{change}" do
      attach_photo
      create(:activity_oshi, activity: activity) if change == :remove_link
      generate
      expect(response).to have_http_status(:ok)
      png = response.body.dup
      receipt = response.headers.fetch("X-Card-Receipt")
      case change
      when :title then activity.update!(title: "changed")
      when :occurred_on then activity.update!(occurred_on: Date.current + 1)
      when :activity_type then activity.update!(activity_type: "その他")
      when :profile then user.profile.update!(display_name: "changed")
      when :oshi_name then activity.oshis.first.update!(name: "changed")
      when :add_link then create(:activity_oshi, activity: activity)
      when :remove_link then activity.activity_oshis.first.destroy!
      when :replace_image
        activity.images.first.purge
        attach_photo
      when :add_image then attach_photo
      when :purge_image then activity.images.first.purge
      when :bytes
        blob = activity.images.first.blob
        File.binwrite(blob.service.path_for(blob.key), "broken")
      when :delete
        ActivityOshi.where(activity_id: activity.id).delete_all
        activity.destroy!
      end
      save(png, receipt)
      expect(response).to have_http_status(:conflict)
      expect(response.media_type).to eq("application/json")
    end
  end

  it "rejects a source update during rendering instead of returning an old receipt" do
    allow_any_instance_of(Cards::Memory).to receive(:render).and_wrap_original do |original|
      png = original.call
      activity.update!(title: "updated during render")
      png
    end
    generate
    expect(response).to have_http_status(:conflict)
    expect(response.headers["X-Card-Receipt"]).to be_nil
  end

  it "expires at fifteen minutes and rejects another login session of the owner" do
    generate
    png = response.body.dup
    receipt = response.headers.fetch("X-Card-Receipt")
    travel 15.minutes do
      save(png, receipt)
      expect(response).to have_http_status(:gone)
    end
    delete destroy_user_session_path
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
    save(png, receipt)
    expect(response).to have_http_status(:forbidden)
  end

  [ :foreign_activity, :future_activity, :other_activity_image, :foreign_image ].each do |invalid|
    it "rejects unauthorized selection #{invalid}" do
      records = [ activity ]
      options = {}
      case invalid
      when :foreign_activity then records = [ create(:activity) ]
      when :future_activity then records = [ create(:activity, user: user, occurred_on: Date.current + 1) ]
      else
        owner = create(:activity, user: invalid == :foreign_image ? create(:user) : user)
        attach_photo(owner)
        options[:image_attachment_ids] = [ owner.images.first.id.to_s ]
      end
      generate(records, **options)
      expect(response).to have_http_status(:not_found)
      expect(response.headers["X-Card-Receipt"]).to be_nil
    end
  end

  [ { activity_ids: [] }, { activity_ids: %w[1 1] }, { activity_ids: %w[1 2 3 4] }, { activity_ids: [ 1 ] },
    { activity_ids: { id: "1" } }, { activity_ids: [ "-1" ] }, { activity_ids: [ "9223372036854775808" ] },
    { image_attachment_ids: [] }, { image_attachment_ids: [ nil ] }, { image_attachment_ids: [ 1 ] },
    { unexpected: true }, { show_introduction: true } ].each do |settings|
    it "rejects malformed settings #{settings.inspect}" do
      generate(**settings)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.headers["X-Card-Receipt"]).to be_nil
    end
  end

  [ nil, [], [ nil ], [ { x: "0.5", y: 0.5, zoom: 1 } ], [ { x: 0.5, y: 0.5, zoom: 0.9 } ],
    [ { x: 0.5, y: 0.5, zoom: 3.1 } ], [ { x: -1, y: 0.5, zoom: 1 } ], [ { x: 0, y: 0.5, zoom: 1 } ],
    [ { x: 0.5, y: 0.5, zoom: 1, extra: 1 } ] ].each do |crops|
    it "rejects invalid memory crop #{crops.inspect}" do
      attach_photo
      generate(crops: crops)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.headers["X-Card-Receipt"]).to be_nil
    end
  end

  it "distinguishes absent images from broken or unavailable registered originals" do
    generate
    expect(response).to have_http_status(:ok)
    attach_photo
    blob = activity.images.first.blob
    path = blob.service.path_for(blob.key)
    File.binwrite(path, "broken")
    generate
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("未登録とは異なる状態")
    File.unlink(path)
    generate
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("未登録とは異なる状態")
  end

  it "validates settings recovered from signed receipts rather than trusting their shape" do
    generate
    png = response.body.dup
    verifier = Rails.application.message_verifier(CardsController::PURPOSE)
    payload = verifier.verified(response.headers.fetch("X-Card-Receipt"), purpose: CardsController::PURPOSE)
    [ { "template" => "memory", "activity_ids" => "wrong" }, { "template" => "data" },
      payload["settings"].merge("extra" => "ignored?") ].each do |settings|
      changed = payload.merge("settings" => settings)
      save(png, verifier.generate(changed, purpose: CardsController::PURPOSE))
      expect(response).to have_http_status(:conflict)
    end
    save(png, verifier.generate(payload.merge("settings" => []), purpose: CardsController::PURPOSE))
    expect(response).to have_http_status(:unprocessable_content)
  end
end
