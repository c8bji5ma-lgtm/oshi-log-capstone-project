require "rails_helper"

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

  it "creates, lists, updates and deletes a common image through the browser" do
    sign_in_as_admin
    visit admin_oshi_common_images_path(q: oshi.name)
    expect(page).to have_css("h1", text: "推し共通画像管理")
    click_link "共通画像を追加"

    attach_file "画像ファイル（必須）", Rails.root.join("spec/fixtures/files/image.png")
    fill_in "出典URL（必須）", with: "https://example.com/graduation-fixture"
    fill_in "作者・権利者（必須）", with: "検証用の作成者"
    fill_in "ライセンス・利用許諾（必須）", with: "検証用の許諾"
    fill_in "帰属表示（必須）", with: "検証用の画像"
    fill_in "oshi_common_image_rights_confirmed_at", with: "2026-10-26T10:00"
    click_button "共通画像を登録"

    expect(page).to have_content("共通画像を登録しました。")
    record = OshiCommonImage.find_by!(oshi: oshi)
    expect(record.image).to be_attached
    expect(page).to have_content("検証用の作成者")

    click_link "編集", exact: true
    fill_in "作者・権利者（必須）", with: "更新した作成者"
    click_button "共通画像情報を更新"

    expect(page).to have_content("共通画像情報を更新しました。")
    expect(record.reload.creator_name).to eq("更新した作成者")
    expect(page).to have_content("更新した作成者")

    accept_confirm("この共通画像を削除しますか？") do
      click_button "削除", exact: true
    end
    expect(page).to have_content("共通画像を削除しました。")
    expect(OshiCommonImage.exists?(record.id)).to be(false)
    expect(page).to have_content("共通画像：0/10枚")
  end
end
