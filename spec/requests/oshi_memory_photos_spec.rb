require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Oshi memory photos", type: :request do
  include ImageAttachments

  let(:user) { create(:user) }
  let(:oshi) { create(:user_oshi, user: user) }

  def login
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def activity(day, photo: true, owner: user)
    record = build(:activity, :without_oshis, user: owner, occurred_on: Date.new(2026, 10, day))
    record.activity_oshis.build(oshi: oshi.oshi)
    record.save!
    record.images.attach(image_upload) if photo
    record
  end

  it "shows the latest three photo-bearing activities independently of the recent activities list" do
    older = activity(1)
    third = activity(2)
    second = activity(3)
    first = activity(4)
    first.images.attach(image_upload("image.jpg"))
    newest = activity(5, photo: false)
    foreign = create(:user)
    create(:user_oshi, user: foreign, oshi: oshi.oshi)
    activity(6, owner: foreign)

    login
    get user_oshi_path(oshi)
    doc = Nokogiri::HTML(response.body)
    photos = doc.at_css("#oshi-memory-photos-heading").parent
    recent = doc.at_css("#recent-oshi-activities-heading").parent
    expect(photos.css("li a").map { |link| link["href"] }).to eq(
      [ first, second, third ].map { |a| activity_path(a, memory_origin: oshi.id, memory_photo: a.images_attachments.order(:id).first.id) }
    )
    expect(photos.css("img").map { |img| img["src"] }).to eq(
      [ first, second, third ].map { |a| protected_activity_preview_path(a.images_attachments.order(:id).first) }
    )
    expect(photos.css("time").first["datetime"]).to eq("2026-10-04")
    expect(recent.css("li a").map { |link| link["href"] }).to eq([ newest, first, second ].map { |a| activity_path(a) })
    expect(photos.css("li a").map { |link| link["href"].split("?").first }).not_to include(activity_path(older))
    expect(doc.at_css("#library-heading")).to be_present
  end

  it "features the exact selected thumbnail ahead of the narrative without changing the image gallery" do
    record = activity(1)
    record.images.attach(image_upload("image.jpg"))
    photos = record.images_attachments.order(:id).to_a
    login
    get activity_path(record, memory_origin: oshi.id, memory_photo: photos.last.id)

    doc = Nokogiri::HTML(response.body)
    feature = doc.at_css(".activity-memory-feature")
    expect(feature.element_children.first["src"]).to eq(protected_activity_preview_path(photos.last))
    expect(feature.next_element["class"]).to eq("detail-rows")
    expect(doc.css(".image-gallery img").map { |img| img["src"] }).to match_array(photos.map { |photo| protected_image_path(photo) })
  end

  it "returns to the originating gallery even when more than one oshi is linked" do
    record = activity(1)
    source = create(:user_oshi, user: user)
    record.activity_oshis.create!(oshi: source.oshi)
    photo = record.images_attachments.first
    filters = { month: "2026-10", q: "ライブ" }
    login

    get user_oshi_path(source)
    gallery = Nokogiri::HTML(response.body).at_css("#oshi-memory-photos-heading").parent
    detail = gallery.at_css("a")["href"]
    expect(detail).to eq(activity_path(record, memory_origin: source.id, memory_photo: photo.id))

    get detail, params: { list_context: filters }
    links = Nokogiri::HTML(response.body).css("a")
    back = links.find { |link| link.text == "#{source.oshi.name}の思い出の写真へ戻る" }
    expect(back["href"]).to eq(user_oshi_path(source, anchor: "oshi-memory-photos-heading"))
    expect(links.map { |link| link["href"] }).not_to include(user_oshi_path(oshi, anchor: "oshi-memory-photos-heading"))
    expect(links.find { |link| link.text == "活動記録一覧へ戻る" }["href"]).to eq(activities_path(filters))
  end

  it "keeps normal detail for an ordinary link or unrelated, unauthorised, malformed or stale context" do
    record = activity(1)
    other_photo = activity(2).images_attachments.first
    photo = record.images_attachments.first
    other_oshi = create(:user_oshi, user: user)
    foreign_registration = create(:user_oshi, oshi: oshi.oshi)
    login

    [
      {},
      { memory_origin: oshi.id },
      { memory_origin: oshi.id, memory_photo: [ photo.id ] },
      { memory_origin: "0", memory_photo: photo.id },
      { memory_origin: other_oshi.id, memory_photo: photo.id },
      { memory_origin: foreign_registration.id, memory_photo: photo.id },
      { memory_origin: oshi.id, memory_photo: other_photo.id },
      { memory_origin: oshi.id, memory_photo: "0" },
      { memory_origin: [ oshi.id ], memory_photo: photo.id }
    ].each do |context|
      get activity_path(record, **context)
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css(".activity-memory-feature")).to be_nil
      expect(doc.at_css('a[href$="#oshi-memory-photos-heading"]')).to be_nil
    end
  end

  it "does not render an empty gallery" do
    activity(1, photo: false)
    login
    get user_oshi_path(oshi)
    expect(Nokogiri::HTML(response.body).at_css("#oshi-memory-photos-heading")).to be_nil
  end

  it "serves a bounded private thumbnail without changing storage" do
    record = activity(1, photo: false)
    original = Vips::Image.black(640, 480, bands: 3).write_to_buffer(".png")
    record.images.attach(image_upload_data(original))
    attachment = record.images_attachments.first
    login
    get protected_activity_preview_path(attachment)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/webp")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.headers["Vary"]).to include("Cookie")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.headers["Location"]).to be_nil
    preview = Vips::Image.new_from_buffer(response.body, "")
    expect([ preview.width, preview.height ]).to eq([ 256, 192 ])
    expect(attachment.blob.download).to eq(original)
  end

  it "does not return originals for guests, wrong association, or corrupt storage" do
    record = activity(1)
    attachment = record.images_attachments.first
    get protected_activity_preview_path(attachment)
    expect(response).to have_http_status(:unauthorized)

    login
    oshi.representative_image.attach(image_upload)
    get protected_activity_preview_path(oshi.representative_image.attachment)
    expect(response).to have_http_status(:not_found)

    attachment.blob.service.upload(attachment.blob.key, StringIO.new("not an image"))
    get protected_activity_preview_path(attachment)
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
  end

  it "does not serve another user's thumbnail" do
    foreign = create(:user)
    create(:user_oshi, user: foreign, oshi: oshi.oshi)
    attachment = activity(1, owner: foreign).images_attachments.first
    login
    get protected_activity_preview_path(attachment)
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
  end
end
