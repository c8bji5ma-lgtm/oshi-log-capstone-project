require "rails_helper"
require "tmpdir"

RSpec.describe "Choosing an unsupported image", type: :system do
  around do |example|
    Dir.mktmpdir("oshilog-format-guidance-") do |directory|
      @test_storage = ActiveStorage::Service::DiskService.new(root: directory)
      @test_storage.name = "test"
      example.run
    end
  end

  it "keeps the draft through unsupported photos and saves it after choosing a JPEG" do
    allow(ActiveStorage::Blob).to receive(:service).and_return(@test_storage)
    allow(ActiveStorage::Blob).to receive(:services).and_return({ "test" => @test_storage })
    user = create(:user)
    registration = create(:user_oshi, user: user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit new_activity_path(initial_oshi_id: registration.oshi_id)
    fill_in "activity_title", with: "残しておきたい記録"
    fill_in "activity_memo", with: "写真を選び直しても残したいメモ"
    select "ライブ・イベント", from: "カテゴリ（必須）"

    [
      [ "photo", "image/heic", "HEIC／HEIF画像は使えません。JPEGなどで書き出して選び直してください。" ],
      [ "photo.HEIF", "", "HEIC／HEIF画像は使えません。JPEGなどで書き出して選び直してください。" ],
      [ "photo.gif", "image/gif", "JPEG・PNG・WebP形式の画像を選び直してください。" ]
    ].each do |file, mime, message|
      page.execute_script(<<~JS, file, mime)
        const input = document.querySelector("#activity_images");
        const transfer = new DataTransfer();
        transfer.items.add(new File(["synthetic test file"], arguments[0], { type: arguments[1] }));
        input.files = transfer.files;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      JS

      expect(page).to have_css("#activity-image-status", text: message)
      expect(page.evaluate_script("document.querySelector('#activity_images').files.length")).to eq(0)
      expect(page).to have_field("activity_title", with: "残しておきたい記録")
      expect(page).to have_field("activity_memo", with: "写真を選び直しても残したいメモ")
    end

    attach_file "activity_images", Rails.root.join("spec/fixtures/files/image.jpg")
    expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
    expect(page).not_to have_css("#activity-image-status", text: "HEIC／HEIF画像は使えません")
    click_button "記録する", exact: true
    expect(page).to have_current_path(activities_path)

    activity = user.activities.find_by!(title: "残しておきたい記録")
    expect(activity.memo).to eq("写真を選び直しても残したいメモ")
    expect(activity.images_attachments.sole.blob.content_type).to eq("image/jpeg")
  end
end
