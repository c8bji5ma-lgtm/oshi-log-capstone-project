require "rails_helper"
require "tmpdir"
require_relative "../support/card_images"

RSpec.describe "Photo cards using the oshi image library", type: :request do
  include CardImages
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:record) { create(:user_oshi, user: user) }

  around do |example|
    services, service = ActiveStorage::Blob.services, ActiveStorage::Blob.service
    Dir.mktmpdir("photo-library-request-") do |directory|
      disk = ActiveStorage::Service::DiskService.new(root: directory)
      disk.name = "test"
      ActiveStorage::Blob.services = { "test" => disk }
      ActiveStorage::Blob.service = disk
      example.run
    ensure
      ActiveStorage::Blob.services, ActiveStorage::Blob.service = services, service
    end
  end

  before do
    create(:profile, user: user)
    login
  end

  def login(account = user)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def color_image(target = record, color = [ 0, 0, 255 ], name: :library_images)
    bytes = Vips::Image.black(20, 30, bands: 3).new_from_image(color).copy(interpretation: :srgb).write_to_buffer(".png")
    target.public_send(name).attach(io: StringIO.new(bytes), filename: "color.png", content_type: "image/png")
    ActiveStorage::Attachment.where(record: target, name: name).order(:id).last!
  end

  def generate(images, owners: nil, records: [ record ], **settings)
    post card_path, params: { card: { user_oshi_ids: records.map { |item| item.id.to_s },
      image_user_oshi_ids: owners || Array.new(records.size, record.id.to_s),
      image_attachment_ids: images, show_introduction: true }.merge(settings) }, as: :json
  end

  def capture_preview(image = color_image)
    generate([ image.id.to_s ])
    expect(response).to have_http_status(:ok)
    [ response.body.dup, response.headers.fetch("X-Card-Receipt") ]
  end

  def download(png, receipt)
    post download_card_path, params: png, headers: { "CONTENT_TYPE" => "image/png", "X-Card-Receipt" => receipt }
  end

  it "offers 30 deduplicated images and preloads metadata without downloading originals" do
    representative = color_image(record, [ 255, 0, 0 ], name: :representative_image)
    record.library_images.attach(representative.blob)
    29.times { color_image }
    foreign = create(:user_oshi)
    foreign_image = color_image(foreign)
    expect(Cards::ImageSource).not_to receive(:read)
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:download)
    get new_card_path
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    input = document.at_css("input[value='#{record.id}'][data-images]")
    images = JSON.parse(input["data-images"])
    expect(images.map { |image| image["id"] }).to eq(record.reload.image_library.map { |image| image.id.to_s })
    expect(images.size).to eq(30)
    expect(images.count { |image| image["representative"] }).to eq(1)
    expect(images.first["id"]).not_to eq(representative.id.to_s)
    expect(images.map { |image| image["url"] }).to all(start_with("/images/"))
    expect(document.css("img[src]")).to be_empty
    expect(document.css("[data-images]").map { |node| node["value"] }).not_to include(foreign.id.to_s)
    expect(response.body).not_to include(protected_image_path(foreign_image))
  end

  it "preserves legacy rendering and renders a selected additional image in the same fixed layout" do
    representative = color_image(record, [ 255, 0, 0 ], name: :representative_image)
    extra = color_image
    post card_path, params: { card: { user_oshi_ids: [ record.id.to_s ], image_user_oshi_ids: [ record.id.to_s ], show_introduction: true } }, as: :json
    expect(response).to have_http_status(:ok)
    legacy = response.body.dup
    generate([ representative.id.to_s ])
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(legacy)
    original_blob = extra.blob.reload.attributes
    queries = []
    callback = ->(*args) { queries << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { generate([ extra.id.to_s ]) }
    expect(response).to have_http_status(:ok)
    additional = response.body.dup
    expect(Vips::Image.new_from_buffer(legacy, "").getpoint(48, 176).take(3)).to eq([ 255, 0, 0 ])
    expect(Vips::Image.new_from_buffer(additional, "").getpoint(48, 176).take(3)).to eq([ 0, 0, 255 ])
    image = Vips::Image.new_from_buffer(additional, "")
    expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
    expect(queries.join).not_to match(/\b(?:activities|activity_oshis|subscriptions)\b/i)
    receipt = response.headers.fetch("X-Card-Receipt")
    download(additional, receipt)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(additional)
    expect(extra.blob.reload.attributes).to eq(original_blob)
    directory = Rails.root.join("tmp/issue70b")
    FileUtils.mkdir_p(directory)
    File.binwrite(directory.join("representative.png"), legacy)
    File.binwrite(directory.join("additional.png"), additional)
  end

  [ 1, 2, 3, 4 ].each do |count|
    it "uses one library image across #{count} frames without changing frame positions or names" do
      image = color_image
      records = [ record ] + Array.new(count - 1) { create(:user_oshi, user: user) }
      generate([ image.id.to_s ] * count, records: records)
      expect(response).to have_http_status(:ok)
      png = Vips::Image.new_from_buffer(response.body, "")
      xs = { 1 => [ 48 ], 2 => [ 372, 812 ], 3 => [ 152, 592, 1032 ], 4 => [ 72, 440, 808, 1176 ] }.fetch(count)
      xs.each { |x| expect(png.getpoint(x, 176).take(3)).to eq([ 0, 0, 255 ]) }
    end
  end

  it "retains disabled slots and their crop order without reading disabled originals" do
    image = color_image
    records = [ record ] + create_list(:user_oshi, 2, user: user)
    generate([ image.id.to_s, "", image.id.to_s ], owners: [ record.id.to_s, "", record.id.to_s ], records: records)
    expect(response).to have_http_status(:ok)
    png = Vips::Image.new_from_buffer(response.body, "")
    expect(png.getpoint(152, 176).take(3)).to eq([ 0, 0, 255 ])
    expect(png.getpoint(592, 176).take(3)).to eq([ 240, 243, 246 ])
    expect(png.getpoint(1032, 176).take(3)).to eq([ 0, 0, 255 ])
  end

  it "generates an explicitly unused frame without any registered images" do
    generate([ "" ], owners: [ "" ])
    expect(response).to have_http_status(:ok)
    download(response.body.dup, response.headers.fetch("X-Card-Receipt"))
    expect(response).to have_http_status(:ok)
  end

  [ nil, [], {}, "image", 1, [ 1 ], [ true ], [ [] ], [ {} ], [ "0" ], [ "-1" ], [ "1x" ],
    [ "9223372036854775808" ], [ "1", "2" ], [ nil ], [ nil, "valid" ], [ "valid", nil ] ].each do |value|
    it "rejects malformed attachment IDs #{value.inspect} before rendering" do
      image = color_image
      value = value.map { |id| id == "valid" ? image.id.to_s : id } if value.is_a?(Array)
      expect_any_instance_of(Cards::Photo).not_to receive(:render)
      generate(value)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.headers["X-Card-Receipt"]).to be_nil
    end
  end

  it "rejects inconsistent owner/attachment pairs, unknown keys and arbitrary URLs" do
    image = color_image
    generate([ "" ])
    expect(response).to have_http_status(:unprocessable_content)
    generate([ image.id.to_s ], owners: [ "" ])
    expect(response).to have_http_status(:unprocessable_content)
    generate([ image.id.to_s ], image_url: "http://example.com/image.png")
    expect(response).to have_http_status(:unprocessable_content)
    generate([ image.id.to_s ], crops: [ Cards::Crop::DEFAULT.merge("attachment_id" => image.id.to_s) ])
    expect(response).to have_http_status(:unprocessable_content)
    generate([ image.id.to_s ], crops: [ nil, Cards::Crop::DEFAULT ])
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("調整範囲が不正")
  end

  it "rejects malformed settings supplied through the query without crashing on an empty JSON body" do
    query = { card: { user_oshi_ids: [ record.id.to_s ], image_user_oshi_ids: [ "" ] } }.to_query
    [ "{}", "", "[]", "null" ].each do |body|
      post "#{card_path}?#{query}", params: body, headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "refuses foreign, unselected, mismatched-owner, detached and nonexistent attachments" do
    own_image = color_image
    second = create(:user_oshi, user: user)
    second_image = color_image(second)
    foreign = create(:user_oshi)
    foreign_image = color_image(foreign)
    [ second_image, foreign_image ].each do |image|
      generate([ image.id.to_s ])
      expect(response).to have_http_status(:not_found)
    end
    generate([ foreign_image.id.to_s ], records: [ foreign ], owners: [ foreign.id.to_s ])
    expect(response).to have_http_status(:not_found)
    generate([ second_image.id.to_s, "" ], records: [ record, second ], owners: [ record.id.to_s, "" ])
    expect(response).to have_http_status(:not_found)
    generate([ second_image.id.to_s ], owners: [ second.id.to_s ])
    expect(response).to have_http_status(:unprocessable_content)
    own_image.delete
    generate([ own_image.id.to_s ])
    expect(response).to have_http_status(:not_found)
    generate([ "9223372036854775807" ])
    expect(response).to have_http_status(:not_found)
  end

  it "does not substitute a representative or confuse a blob ID with an attachment ID" do
    color_image(record, [ 255, 0, 0 ], name: :representative_image)
    image = color_image
    generate([ image.blob.signed_id ])
    expect(response).to have_http_status(:unprocessable_content)
    generate([ "#{image.id}invalid" ])
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "does not invalidate a preview when another library image is added, removed or made representative" do
    image = color_image
    png, receipt = capture_preview(image)
    other = color_image(record, [ 255, 0, 0 ])
    UserOshis::Save.call(user_oshi: record.reload, representative_image_id: other.id.to_s)
    download(png, receipt)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png)
    UserOshis::Save.call(user_oshi: record.reload, remove_image_id: other.id.to_s, clear_representative: true)
    download(png, receipt)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png)
  end

  %i[deleted detached owner_changed blob_replaced bytes_changed checksum_changed file_missing].each do |mutation|
    it "refuses download when the selected image is #{mutation} after preview" do
      image = color_image
      other = color_image(record, [ 255, 0, 0 ])
      png, receipt = capture_preview(image)
      case mutation
      when :deleted
        UserOshis::Save.call(user_oshi: record.reload, remove_image_id: image.id.to_s)
      when :detached
        image.delete
      when :owner_changed
        image.update!(record: create(:user_oshi, user: user))
      when :blob_replaced
        replacement = other.blob
        other.delete
        image.update!(blob: replacement)
      when :bytes_changed
        image.blob.service.upload(image.blob.key, StringIO.new(other.download))
      when :checksum_changed
        image.blob.update!(checksum: "changed")
      when :file_missing
        image.blob.service.delete(image.blob.key)
      end
      expect_any_instance_of(Cards::Photo).not_to receive(:render)
      download(png, receipt)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.fetch("error")).to include("再生成")
    end
  end

  it "detects a selected attachment changed during rendering" do
    image = color_image
    allow_any_instance_of(Cards::Photo).to receive(:render).and_wrap_original do |method|
      png = method.call
      image.delete
      png
    end
    generate([ image.id.to_s ])
    expect(response).to have_http_status(:not_found)
    expect(response.headers["X-Card-Receipt"]).to be_nil
  end

  it "signs the explicit settings and rejects tampered signatures, PNGs, expired or foreign-session receipts" do
    png, receipt = capture_preview
    verifier = Rails.application.message_verifier(CardsController::PURPOSE)
    payload = verifier.verified(receipt, purpose: CardsController::PURPOSE)
    expect(payload.fetch("settings").fetch("image_attachment_ids")).to eq([ record.reload.image_library.first.id.to_s ])
    expect(receipt.bytesize).to be < 16.kilobytes
    altered = png.dup
    altered.setbyte(altered.bytesize - 1, altered.getbyte(altered.bytesize - 1) ^ 1)
    download(altered, receipt)
    expect(response).to have_http_status(:unprocessable_content)
    download(png, receipt.sub(/.\z/, receipt.end_with?("a") ? "b" : "a"))
    expect(response).to have_http_status(:unprocessable_content)
    travel 15.minutes do
      download(png, receipt)
      expect(response).to have_http_status(:gone)
    end
    delete destroy_user_session_path
    login
    download(png, receipt)
    expect(response).to have_http_status(:forbidden)
    delete destroy_user_session_path
    login(create(:user))
    download(png, receipt)
    expect(response).to have_http_status(:forbidden)
  end
end
