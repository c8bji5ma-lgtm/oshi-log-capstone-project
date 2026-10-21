require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Managing an oshi image library in the browser", type: :system do
  include ImageAttachments
  let(:user) { create(:user) }

  def login
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    expect(page).to have_current_path(root_path)
  end

  def fixture_path(name)
    Rails.root.join("spec/fixtures/files", name).to_s
  end

  def expect_images_loaded
    expect(page).to have_css("main img")
    expect(page).to have_css("main img", visible: true)
    expect(page.evaluate_script("Array.from(document.querySelectorAll('main img')).every(image => image.complete && image.naturalWidth > 0)")).to be(true)
  end

  it "registers multiple images, appends, selects, and explicitly confirms deletion" do
    oshi = create(:oshi, :approved)
    login
    visit new_oshi_path(q: oshi.name)
    within("form[action='#{user_oshis_path}']") do
      select oshi.name, from: "既存候補"
      attach_file "登録画像", [ fixture_path("image.jpg"), fixture_path("image.webp") ]
      click_button "選んだ推しを追加"
    end
    expect(page).to have_current_path(oshis_path)
    record = user.user_oshis.find_by!(oshi: oshi)
    visit edit_user_oshi_path(record)
    expect(page).to have_text("2/30枚（残り28枚）")
    attach_file "追加画像", fixture_path("image.png")
    click_button "画像を追加"
    expect(page).to have_text("3/30枚（残り27枚）")
    expect(page).to have_css(".oshi-image-gallery li", count: 3)
    first, second = record.reload.image_library
    within("[data-image-id='#{second.id}']") { click_button "代表画像にする" }
    expect(page).to have_css("[role='status']", text: "代表画像を変更しました。")
    within("[data-image-id='#{second.id}']") { expect(page).to have_text("代表画像") }
    expect(record.reload.image_count).to eq(3)

    within("[data-image-id='#{first.id}']") do
      expect(page).not_to have_button("画像1の削除を確定")
      find("summary").click
      click_button "画像1の削除を確定"
    end
    expect(page).to have_text("2/30枚（残り28枚）")
    within("[data-image-id='#{second.id}']") do
      find("summary").click
      expect(page).to have_unchecked_field("代表画像を解除して削除する")
      check "代表画像を解除して削除する"
      click_button "画像1の削除を確定"
    end
    expect(page).to have_text("1/30枚（残り29枚）")
    expect(record.reload.representative_image).not_to be_attached
    expect_images_loaded
  end

  it "keeps images and information separate at 375px and shows usable galleries and forms" do
    record = create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "長い名前の推しと作品名を含むスマートフォン表示確認"))
    record.representative_image.attach(image_upload("image.jpg"))
    record.library_images.attach([ image_upload("image.png"), image_upload("image.webp") ])
    login
    visit oshis_path
    expect_images_loaded
    directory = Rails.root.join("tmp/issue70")
    FileUtils.mkdir_p(directory)
    page.save_screenshot(directory.join("list-desktop.png"))
    page.current_window.resize_to(375, 900)
    { list: oshis_path, show: user_oshi_path(record), edit: edit_user_oshi_path(record), new: new_oshi_path(q: record.oshi.name) }.each do |name, path|
      visit path
      expect(page).to have_css("main h1")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      if name == :list
        expect_images_loaded
        geometry = page.evaluate_script(<<~JS)
          (() => {
            const image = document.querySelector('.oshi-list-image');
            const info = document.querySelector('.oshi-list-info');
            return { width: image.width, height: image.height,
              fit: getComputedStyle(image).objectFit,
              separate: image.getBoundingClientRect().right <= info.getBoundingClientRect().left };
          })()
        JS
        expect(geometry).to eq("width" => 120, "height" => 120, "fit" => "contain", "separate" => true)
      elsif [ :show, :edit ].include?(name)
        expect(page).to have_css(".oshi-image-gallery li", count: 3)
        expect(page).to have_text("3/30枚（残り27枚）")
      end
      page.save_screenshot(directory.join("#{name}-375.png"))
      if [ :show, :edit ].include?(name)
        page.execute_script("arguments[0].scrollIntoView({block: 'start', behavior: 'instant'})", find(".oshi-image-library"))
        page.save_screenshot(directory.join("#{name}-gallery-375.png"))
      end
    end
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  it "uploads multiple originals and blocks a failed batch before submitting the new-oshi form" do
    login
    visit new_oshi_path
    within("form[action='#{oshis_path}']") do
      expect(find(:css, "input[type='file']")[:multiple]).to be_present
      fill_in "推し名（必須）", with: "画像付きの新規推し"
      select "アイドル", from: "種別（必須）"
      attach_file "登録画像", [ fixture_path("image.jpg"), fixture_path("invalid.txt") ]
      expect(page).to have_css("#new-image-help-status[role='alert']", text: "JPEG・PNG・WebP")
      expect(page.evaluate_script("arguments[0].files.length", find_field("登録画像"))).to eq(0)
    end
    expect(page).to have_field("推し名（必須）", with: "画像付きの新規推し")
    expect(user.user_oshis).to be_empty
    within("form[action='#{oshis_path}']") do
      attach_file "登録画像", [ fixture_path("image.jpg"), fixture_path("image.webp") ]
      click_button "新しい推しを登録"
    end
    expect(page).to have_current_path(oshis_path)
    target = user.user_oshis.last!
    expect(target.image_count).to eq(2)
    expect(target.representative_image.filename.to_s).to eq("image.jpg")
  end
end
