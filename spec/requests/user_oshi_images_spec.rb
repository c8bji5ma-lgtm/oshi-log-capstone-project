require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Personal oshi image libraries", type: :request do
  include ImageAttachments

  let(:user) { create(:user) }
  let(:record) { create(:user_oshi, user: user) }

  def login(account = user)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def upload(filename = "image.png")
    type = { "image.png" => "image/png", "image.jpg" => "image/jpeg", "image.webp" => "image/webp", "invalid.txt" => "text/plain" }.fetch(filename)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files", filename), type)
  end

  def sized_upload(filename, size)
    type = { "image.png" => "image/png", "image.jpg" => "image/jpeg", "image.webp" => "image/webp" }.fetch(filename)
    tempfile = Tempfile.new([ "request-image-", File.extname(filename) ])
    tempfile.binmode
    tempfile.write(File.binread(Rails.root.join("spec/fixtures/files", filename)).ljust(size, "\0"))
    tempfile.rewind
    (@sized_uploads ||= []) << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, type, true, original_filename: filename)
  end

  def add_images(files, target = record)
    post user_oshi_images_path(target), params: { user_oshi: { library_images: files } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  it "requires login for upload, selection, and deletion" do
    record.library_images.attach(image_upload)
    image = record.library_images.first
    counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    add_images([ upload ])
    expect(response).to redirect_to(new_user_session_path)
    patch user_oshi_image_path(record, image)
    expect(response).to redirect_to(new_user_session_path)
    delete user_oshi_image_path(record, image)
    expect(response).to redirect_to(new_user_session_path)
    expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
  end

  context "when signed in" do
    before { login }

    it "registers multiple images for a new pending oshi and selects the first original" do
      post oshis_path, params: { oshi: { name: "複数画像の新規推し", oshi_type: "アイドル" },
        user_oshi: { library_images: [ upload("image.jpg"), upload("image.webp") ] } }
      expect(response).to redirect_to(oshis_path)
      target = user.user_oshis.last!
      expect(target.oshi).to be_pending
      expect(target.image_count).to eq(2)
      expect(target.representative_image.filename.to_s).to eq("image.jpg")
    end

    it "registers multiple images when adding an existing visible oshi" do
      oshi = create(:oshi, :approved)
      post user_oshis_path, params: { oshi_id: oshi.id,
        user_oshi: { library_images: [ upload, upload("image.webp") ] } }
      expect(response).to redirect_to(oshis_path)
      expect(user.user_oshis.find_by!(oshi: oshi).image_count).to eq(2)
    end

    it "rolls back a new oshi and all image rows when one image is invalid" do
      counts = [ Oshi.count, UserOshi.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
      post oshis_path, params: { oshi: { name: "失敗する登録", oshi_type: "アイドル" },
        user_oshi: { library_images: [ upload, upload("invalid.txt") ] } }
      expect(response).to have_http_status(:unprocessable_content)
      expect([ Oshi.count, UserOshi.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]).to eq(counts)
      expect(document.css(".validation-errors").text).to include("JPEG")
    end

    it "rejects a mixed invalid batch when adding an existing oshi" do
      oshi = create(:oshi, :approved)
      expect do
        post user_oshis_path, params: { oshi_id: oshi.id, user_oshi: { library_images: [ upload, upload("invalid.txt") ] } }
      end.not_to change(UserOshi, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors").text).to include("JPEG")
    end

    it "appends images without replacing the old library or representative" do
      record.representative_image.attach(image_upload("image.jpg"))
      original = record.representative_image.blob_id
      add_images([ upload, upload("image.webp") ])
      expect(response).to redirect_to(edit_user_oshi_path(record))
      expect(record.reload.image_count).to eq(3)
      expect(record.representative_image.blob_id).to eq(original)
      add_images([ upload ])
      expect(record.reload.image_count).to eq(4)
      get edit_user_oshi_path(record)
      expect(document.css(".image-count").text).to include("4/30枚", "残り26枚")
    end

    it "shows a recoverable Japanese error for a batch over 10 MiB and keeps saved images" do
      record.representative_image.attach(image_upload("image.jpg"))
      original_id = record.representative_image.blob_id
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      files = [ sized_upload("image.png", 5.megabytes), sized_upload("image.webp", 5.megabytes + 1) ]

      add_images(files)

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors").text).to include("1回の送信合計を10 MiB以下", "分けて追加")
      expect(document.css(".oshi-image-gallery img").size).to eq(1)
      expect(record.reload.representative_image.blob_id).to eq(original_id)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end

    it "rejects image 31 sent directly and keeps the saved image gallery in the error response" do
      record.representative_image.attach(image_upload)
      record.library_images.attach(Array.new(29) { image_upload })
      ids = record.reload.image_library.map(&:id)
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      add_images([ upload ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors").text).to include("30")
      expect(document.css(".oshi-image-gallery img").size).to eq(30)
      expect(record.reload.image_library.map(&:id)).to eq(ids)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      expect(document.at_css("input[value='画像を追加']")["disabled"]).to be_present
    end

    it "rejects 31 images during new registration" do
      expect do
        post oshis_path, params: { oshi: { name: "上限超過", oshi_type: "アイドル" },
          user_oshi: { library_images: Array.new(31) { upload } } }
      end.not_to change(Oshi, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects tampered upload types including signed blob IDs" do
      record.representative_image.attach(image_upload)
      original = record.representative_image.blob_id
      [ "not-an-array", [ record.representative_image.blob.signed_id ], { id: "1" }, [ { id: "1" } ] ].each do |invalid|
        add_images(invalid)
        expect(response).to have_http_status(:unprocessable_content)
        expect(record.reload.image_count).to eq(1)
        expect(record.representative_image.blob_id).to eq(original)
      end
    end

    it "keeps server errors visible for malformed new-registration uploads" do
      post oshis_path, params: { oshi: { name: "不正な画像入力", oshi_type: "アイドル" },
        user_oshi: { library_images: [ "invalid-blob-id" ] } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors").text).to include("ファイルとして選択")
      expect(user.user_oshis).to be_empty
    end

    it "shows a recoverable error and persists no new oshi after a disk failure" do
      before = [ Oshi.count, UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, "disk unavailable")
      post oshis_path, params: { oshi: { name: "保存失敗", oshi_type: "アイドル" },
        user_oshi: { library_images: [ upload ] } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors").text).to include("保存できませんでした")
      expect([ Oshi.count, UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(before)
    end

    it "rejects malformed representative uploads without silently ignoring them" do
      record.representative_image.attach(image_upload)
      original = record.representative_image.blob_id
      [ [ "invalid" ], { id: "1" } ].each do |invalid|
        patch user_oshi_path(record), params: { user_oshi: { started_period: "2020", representative_image: invalid } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(record.reload.representative_image.blob_id).to eq(original)
        expect(record.started_period).to eq("2023")
      end
    end

    it "selects a registered image, retains the former original, and updates list, detail and edit" do
      record.representative_image.attach(image_upload("image.jpg"))
      old_blob = record.representative_image.blob
      add_images([ upload("image.webp") ])
      image = record.reload.image_library.last
      patch user_oshi_image_path(record, image)
      expect(response).to redirect_to(edit_user_oshi_path(record))
      expect(record.reload.image_count).to eq(2)
      expect(record.representative_image.blob_id).to eq(image.blob_id)
      [ oshis_path, user_oshi_path(record), edit_user_oshi_path(record) ].each do |path|
        get path
        expect(document.at_css("main img")["src"]).to eq(protected_image_path(record.representative_image.attachment))
        expect(document.at_css("main").text).not_to include(old_blob.key)
      end
      expect(record.image_library.map(&:blob_id)).to include(old_blob.id)
      get user_oshi_path(record)
      expect(document.css(".oshi-image-gallery img").size).to eq(2)
      expect(document.css("figcaption").text).to include("代表画像")
    end

    it "shows placeholders and an empty gallery for a user with no images" do
      [ oshis_path, user_oshi_path(record), edit_user_oshi_path(record) ].each do |path|
        get path
        expect(document.at_css("main img")["src"]).to include("image_placeholder")
      end
      expect(document.css(".image-count").text).to include("0/30枚", "残り30枚")
    end

    it "deletes one image and revokes both library and representative URLs after explicit clearance" do
      add_images([ upload, upload("image.webp") ])
      image = record.reload.image_library.first
      paths = [ protected_image_path(image), protected_image_path(record.representative_image.attachment) ]
      delete user_oshi_image_path(record, image)
      expect(response).to have_http_status(:unprocessable_content)
      expect(record.reload.image_count).to eq(2)
      delete user_oshi_image_path(record, image), params: { clear_representative: "1" }
      expect(response).to redirect_to(edit_user_oshi_path(record))
      expect(record.reload.representative_image).not_to be_attached
      expect(record.image_count).to eq(1)
      paths.each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
    end

    it "can change representative then delete the former image without clearing the new representative" do
      add_images([ upload, upload("image.webp") ])
      first, second = record.reload.image_library
      patch user_oshi_image_path(record, second)
      delete user_oshi_image_path(record, first)
      expect(response).to redirect_to(edit_user_oshi_path(record))
      expect(record.reload.representative_image.blob_id).to eq(second.blob_id)
      expect(record.image_library.map(&:id)).to eq([ second.id ])
    end

    it "refuses upload, selection and deletion on another user's parent" do
      other = create(:user_oshi)
      other.library_images.attach(image_upload)
      image = other.library_images.first
      add_images([ upload ], other)
      expect(response).to have_http_status(:not_found)
      patch user_oshi_image_path(other, image)
      expect(response).to have_http_status(:not_found)
      delete user_oshi_image_path(other, image)
      expect(response).to have_http_status(:not_found)
      expect(other.reload.image_count).to eq(1)
    end

    it "refuses foreign and other-oshi image IDs without changing the current image" do
      record.representative_image.attach(image_upload)
      original = record.representative_image.blob_id
      [ create(:user_oshi), create(:user_oshi, user: user) ].each do |other|
        other.library_images.attach(image_upload)
        image = other.library_images.first
        patch user_oshi_image_path(record, image)
        expect(response).to have_http_status(:not_found)
        delete user_oshi_image_path(record, image), params: { clear_representative: "1" }
        expect(response).to have_http_status(:not_found)
        expect(other.reload.image_count).to eq(1)
      end
      expect(record.reload.representative_image.blob_id).to eq(original)
    end

    it "never renders another user's image URLs on list, detail, or edit" do
      other = create(:user_oshi)
      other.library_images.attach(image_upload)
      foreign_path = protected_image_path(other.library_images.first)
      [ oshis_path, user_oshi_path(record), edit_user_oshi_path(record) ].each do |path|
        get path
        expect(response.body).not_to include(foreign_path)
      end
      [ user_oshi_path(other), edit_user_oshi_path(other) ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include(foreign_path)
      end
    end

    it "preloads representative attachments and blobs with constant query counts on the list" do
      4.times do
        target = create(:user_oshi, user: user)
        target.representative_image.attach(image_upload)
      end
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get oshis_path }
      expect(response).to have_http_status(:ok)
      expect(document.css(".oshi-list-image").size).to eq(4)
      expect(queries.count { |sql| sql.match?(/SELECT.*FROM "active_storage_attachments"/) }).to eq(1)
      expect(queries.count { |sql| sql.match?(/SELECT.*FROM "active_storage_blobs"/) }).to eq(1)
    end
  end

  it "serves library originals only to the owner and retains security response headers" do
    record.library_images.attach(image_upload("image.webp"))
    image = record.library_images.first
    path = protected_image_path(image)
    get path
    expect(response).to have_http_status(:unauthorized)
    login(create(:user))
    get path
    expect(response).to have_http_status(:not_found)
    delete destroy_user_session_path
    login
    get path
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.webp")))
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.headers["Vary"]).to include("Cookie")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.headers["Location"]).to be_nil
  end
end
