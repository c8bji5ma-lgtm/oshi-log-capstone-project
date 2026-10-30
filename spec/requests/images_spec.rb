require "rails_helper"
require_relative "../support/activity_input_context"
require_relative "../support/image_attachments"

RSpec.describe "Protected images", type: :request do
  include ActivityInputContext
  include ImageAttachments

  let(:user) { create(:user) }

  def login(account = user)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def attach_image(kind, owner, filename = "image.png")
    record = create(kind, user: owner)
    association = { profile: :profile_image, user_oshi: :representative_image, activity: :images }.fetch(kind)
    record.public_send(association).attach(image_upload(filename))
    ActiveStorage::Attachment.find_by!(record: record, name: association)
  end

  [ :profile, :user_oshi, :activity ].each do |kind|
    context "with a #{kind} image" do
      let!(:image) { attach_image(kind, user) }
      let(:path) { protected_image_path(image) }

      it "serves the owner's original bytes privately without exposing storage details" do
        login
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
        expect(response.media_type).to eq("image/png")
        expect(response.headers["Cache-Control"]).to include("private", "no-store")
        expect(response.headers["Vary"]).to include("Cookie")
        expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
        expect(response.headers["Content-Disposition"]).to include("inline", "image.png")
        expect(response.headers.values.join).not_to include(image.blob.key, image.blob.signed_id, Rails.root.join("tmp/storage").to_s)
        expect(response.headers["Location"]).to be_nil
        expect(response.headers["X-Sendfile"]).to be_nil
      end

      it "requires authentication even when the attachment URL is known" do
        get path
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      it "rejects other users, including conditional requests with a known URL" do
        login(create(:user))
        get path, headers: { "If-None-Match" => '*', "If-Modified-Since" => 1.day.from_now.httpdate }
        expect(response).to have_http_status(:not_found)
        expect(response.headers["Cache-Control"]).to include("no-store")
        expect(response.body).to be_empty
      end

      it "rejects an old URL after detachment even while the blob remains" do
        login
        blob = image.blob
        image.delete
        expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
        get path
        expect(response).to have_http_status(:not_found)
      end

      it "rejects images whose parent record no longer exists" do
        login
        ActivityOshi.where(activity_id: image.record_id).delete_all if kind == :activity
        image.record.delete
        get path
        expect(response).to have_http_status(:not_found)
      end

      it "rechecks authentication after logout instead of returning a cached image" do
        login
        get path
        expect(response).to have_http_status(:ok)
        delete destroy_user_session_path
        get path, headers: { "If-None-Match" => '*' }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  %w[image.jpg image.webp].each do |filename|
    it "serves original #{filename} bytes" do
      image = attach_image(:profile, user, filename)
      login
      get protected_image_path(image)
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files", filename)))
      expect(response.media_type).to eq(filename.end_with?("jpg") ? "image/jpeg" : "image/webp")
    end
  end

  it "returns 404 for nonexistent attachments" do
    login
    get protected_image_path(id: 0)
    expect(response).to have_http_status(:not_found)
  end

  it "rejects path traversal in a stored key without serving arbitrary files" do
    image = attach_image(:profile, user)
    image.blob.update!(key: "../../Gemfile")
    login
    get protected_image_path(image)
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "returns a private 404 when the storage file is missing" do
    image = attach_image(:profile, user)
    allow_any_instance_of(ActiveStorage::Service::DiskService).to receive(:path_for)
      .and_return(Rails.root.join("tmp/storage/nonexistent-protected-image").to_s)
    login
    get protected_image_path(image)
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to be_empty
  end

  it "does not expose internal paths when a client requests sendfile offloading" do
    image = attach_image(:profile, user)
    login
    get protected_image_path(image), headers: { "X-Sendfile-Type" => "X-Sendfile" }
    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Sendfile"]).to be_nil
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
  end

  it "does not authorize a shared Oshi's other user's representative image" do
    foreign = attach_image(:user_oshi, create(:user))
    create(:user_oshi, user: user, oshi: foreign.record.oshi)
    login
    get protected_image_path(foreign)
    expect(response).to have_http_status(:not_found)
  end

  it "serves HEAD privately and still authorizes it" do
    image = attach_image(:activity, user)
    login
    head protected_image_path(image)
    expect(response).to have_http_status(:ok)
    expect(response.body).to be_empty
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  context "with disabled standard Active Storage endpoints" do
    let!(:image) { attach_image(:profile, user) }

    def standard_paths
      blob = image.blob
      signed = blob.signed_id
      variation = ActiveStorage::Variation.wrap(resize_to_limit: [ 10, 10 ]).key
      disk_token = ActiveStorage.verifier.generate(
        { key: blob.key, disposition: "inline", content_type: blob.content_type, service_name: blob.service.name },
        expires_in: 5.minutes, purpose: :blob_key)
      [
        "/rails/active_storage/blobs/redirect/#{signed}/image.png",
        "/rails/active_storage/blobs/proxy/#{signed}/image.png",
        "/rails/active_storage/blobs/#{signed}/image.png",
        "/rails/active_storage/representations/redirect/#{signed}/#{variation}/image.png",
        "/rails/active_storage/representations/proxy/#{signed}/#{variation}/image.png",
        "/rails/active_storage/representations/#{signed}/#{variation}/image.png",
        "/rails/active_storage/disk/#{disk_token}/image.png"
      ]
    end

    it "rejects actual signed blob, variant and Disk URLs for every login state" do
      paths = standard_paths
      [ nil, user, create(:user) ].each do |account|
        login(account) if account
        paths.each do |path|
          get path
          expect(response).to have_http_status(:not_found), "Unexpected access: #{path}"
        end
        delete destroy_user_session_path if account
      end
    end

    it "rejects direct-upload creation and signed Disk uploads" do
      login
      blob = image.blob
      disk_token = ActiveStorage.verifier.generate(
        { key: blob.key, content_type: blob.content_type, content_length: blob.byte_size,
          checksum: blob.checksum, service_name: blob.service.name },
        expires_in: 5.minutes, purpose: :blob_token)
      expect { post "/rails/active_storage/direct_uploads", params: { blob: { filename: "image.png", byte_size: blob.byte_size, checksum: blob.checksum, content_type: "image/png" } } }
        .not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:not_found)
      put "/rails/active_storage/disk/#{disk_token}", params: "replacement", headers: { "CONTENT_TYPE" => "image/png" }
      expect(response).to have_http_status(:not_found)
      expect(blob.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
    end
  end

  it "rejects another user's signed blob ID as a representative image replacement" do
    foreign = attach_image(:profile, create(:user))
    own = attach_image(:user_oshi, user)
    login
    expect do
      patch user_oshi_path(own.record), params: { user_oshi: { representative_image: foreign.blob.signed_id } }
    end.not_to change(ActiveStorage::Attachment, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(own.record.reload.representative_image.blob_id).to eq(own.blob_id)
    get protected_image_path(foreign)
    expect(response).to have_http_status(:not_found)
  end

  it "rejects another user's blob as an added activity image" do
    foreign = attach_image(:profile, create(:user))
    own = attach_image(:activity, user)
    login
    expect do
      patch activity_path(own.record), params: { activity: { context_token: activity_form_context(edit_activity_path(own.record)), oshi_ids: own.record.oshi_ids.map(&:to_s),
        images: [ foreign.blob.signed_id ], lock_version: own.record.lock_version.to_s } }
    end.not_to change(ActiveStorage::Attachment, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(own.record.reload.images.blobs.pluck(:id)).to eq([ own.blob_id ])
  end

  it "serves an uploaded replacement and revokes the previous representative image URL" do
    image = attach_image(:user_oshi, user)
    old_path = protected_image_path(image)
    login
    patch user_oshi_path(image.record), params: { user_oshi: {
      representative_image: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/image.webp"), "image/webp")
    } }
    expect(response).to redirect_to(oshis_path)
    get user_oshi_path(image.record)
    source = Nokogiri::HTML(response.body).at_css("main img")["src"]
    get source
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.webp")))
    get old_path
    expect(response).to have_http_status(:not_found)
  end

  it "uploads and appends activity images through forms, then revokes their URLs on deletion" do
    personal_oshi = create(:user_oshi, user: user)
    login
    post activities_path, params: { activity: {
      context_token: activity_form_context, occurred_on: "2026-10-01", title: "画像付き活動", activity_type: Activity::ACTIVITY_TYPES.first,
      oshi_ids: [ personal_oshi.oshi_id.to_s ],
      images: [ Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/image.png"), "image/png") ]
    } }
    expect(response).to redirect_to(activities_path)
    activity = user.activities.last!
    patch activity_path(activity), params: { activity: {
      context_token: activity_form_context(edit_activity_path(activity)), oshi_ids: [ personal_oshi.oshi_id.to_s ],
      lock_version: activity.lock_version.to_s,
      images: [ Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/image.jpg"), "image/jpeg") ]
    } }
    expect(response).to redirect_to(activity_path(activity))
    get activity_path(activity)
    paths = Nokogiri::HTML(response.body).css(".image-gallery img").map { |image| image["src"] }
    expect(paths.size).to eq(2)
    paths.zip(%w[image.png image.jpg]).each do |path, filename|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files", filename)))
    end
    delete activity_path(activity)
    expect(response).to redirect_to(activities_path)
    paths.each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
  end

  it "serves the existing seed image asset through the protected endpoint" do
    profile = create(:profile, user: user)
    asset = Rails.root.join("db/seeds/assets/seed-flowers.jpg")
    File.open(asset, "rb") do |file|
      profile.profile_image.attach(io: file, filename: "seed-flowers.jpg", content_type: "image/jpeg")
    end
    login
    get protected_image_path(profile.profile_image.attachment)
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(File.binread(asset))
  end
end
