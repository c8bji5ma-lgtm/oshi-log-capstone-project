require "rails_helper"
require "tmpdir"

RSpec.describe "管理者の推し共通画像管理", type: :system do
  let!(:admin) { create(:user, :admin) }
  let!(:oshi) { create(:oshi, :approved, name: "共通画像の操作確認") }

  def sign_in_as_admin
    visit new_user_session_path
    within("main form") do
      fill_in "user_email", with: admin.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
    end
    expect(page).to have_current_path(root_path)
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def check_loaded_image(alt)
    expect(page).to have_css("img[alt='#{alt}']", wait: 10) { |image|
      image.evaluate_script("this.complete && this.naturalWidth > 0 && this.naturalHeight > 0")
    }
  end

  around do |example|
    previous_registry = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshilog-admin-common-image-system-") do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      Capybara.reset_sessions!
    end
  ensure
    ActiveStorage::Blob.services = previous_registry
    ActiveStorage::Blob.service = previous_service
  end

  it "registers, displays, edits, disables and confirms deletion of a rights-recorded image" do
    sign_in_as_admin
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    expect(page).to have_css("main h1", text: "マイページ", exact_text: true)
    click_link "推し承認管理"
    click_link "推し共通画像を管理"
    expect(page).to have_css("main h1", text: "推し共通画像管理", exact_text: true)
    fill_in "推しを検索", with: oshi.name
    click_button "検索", exact: true
    within(".common-image-admin-card", text: oshi.name) do
      expect(page).to have_text("共通画像：0/10枚")
      click_link "共通画像を追加"
    end

    expect(page).to have_css("main h1", text: "#{oshi.name}の共通画像登録", exact_text: true)
    attach_file "画像ファイル（必須）", Rails.root.join("spec/fixtures/files/image.png")
    fill_in "出典URL（必須）", with: "https://example.test/source"
    fill_in "作者・権利者（必須）", with: "テスト作者"
    fill_in "ライセンス・利用許諾（必須）", with: "テスト利用許諾"
    fill_in "帰属表示（必須）", with: "画像提供：テスト作者"
    expect(find_field("権利確認日時（必須）").value).to be_present
    click_button "共通画像を登録"
    expect(page).to have_css("[role='status']", text: "共通画像を登録しました。")
    expect(page).to have_current_path(admin_oshi_common_images_path(q: oshi.name))
    record = OshiCommonImage.find_by!(oshi: oshi)
    expect(record.image).to be_attached
    within(".common-image-admin-card", text: oshi.name) do
      expect(page).to have_text("共通画像：1/10枚")
      expect(page).to have_text("状態：有効")
      expect(page).to have_text("作者・権利者：テスト作者")
      expect(page).to have_text("ライセンス：テスト利用許諾")
      check_loaded_image("#{oshi.name}の共通画像")
      click_link "編集", exact: true
    end

    expect(page).to have_css("main h1", text: "#{oshi.name}の共通画像編集", exact_text: true)
    expect(page).to have_field("帰属表示（必須）", with: "画像提供：テスト作者")
    fill_in "作者・権利者（必須）", with: "更新した作者"
    fill_in "ライセンス・利用許諾（必須）", with: "更新した利用許諾"
    fill_in "帰属表示（必須）", with: "画像提供：更新した作者"
    uncheck "有効にする"
    click_button "共通画像情報を更新"
    expect(page).to have_css("[role='status']", text: "共通画像情報を更新しました。")
    expect(record.reload.creator_name).to eq("更新した作者")
    within(".common-image-admin-card", text: oshi.name) do
      expect(page).to have_text("状態：無効")
      expect(page).to have_text("作者・権利者：更新した作者")
      expect(page).to have_text("ライセンス：更新した利用許諾")
      expect(page).not_to have_css("img")
      click_link "編集", exact: true
    end
    expect(page).to have_field("帰属表示（必須）", with: "画像提供：更新した作者")
    expect(page).to have_unchecked_field("有効にする")
    click_link "共通画像管理へ戻る"

    dismiss_confirm("この共通画像を削除しますか？") { click_button "削除", exact: true }
    expect(page).to have_text("共通画像：1/10枚")
    expect(page).to have_link("編集", exact: true)
    accept_confirm("この共通画像を削除しますか？") { click_button "削除", exact: true }
    expect(page).to have_css("[role='status']", text: "共通画像を削除しました。")
    expect(OshiCommonImage.exists?(record.id)).to be(false)
    within(".common-image-admin-card", text: oshi.name) do
      expect(page).to have_text("共通画像：0/10枚")
      expect(page).not_to have_css(".common-image-admin-list section")
      expect(page).not_to have_link("編集", exact: true)
      expect(page).not_to have_button("削除", exact: true)
    end
  end
end
