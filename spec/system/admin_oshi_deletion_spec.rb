require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Administrator oshi master deletion", type: :system do
  include ImageAttachments

  [ 375, 1280 ].each do |width|
    it "confirms, cancels and deletes safely by keyboard at #{width}px, while retaining used masters" do
      page.current_window.resize_to(width, 1024)
      admin = create(:user, :admin)
      name = '<script>window.oshiDeletionXss=1</script>"&' + ("長い名称" * 40)
      target = create(:oshi, :approved, name: name)
      used = create(:oshi, :approved, name: "利用中の推し#{width}")
      personal = create(:user_oshi, oshi: used)
      personal.representative_image.attach(image_upload)
      bytes = personal.representative_image.download

      visit new_user_session_path
      fill_in "user_email", with: admin.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
      expect(page).to have_current_path(root_path)
      visit my_page_path
      click_link "推し承認管理"
      click_link "推しマスタを管理"
      expect(page).to have_css("main h1", text: "推しマスタ管理", exact_text: true)
      fill_in "名前・別名・所属・作品で検索", with: name
      click_button "検索"
      expect(page).to have_css("main h2", text: name, exact_text: true)
      click_link "削除内容を確認"
      expect(page).to have_css("#oshi-deletion-target", text: "削除する推し：#{name}", exact_text: true)
      expect(page.evaluate_script("window.oshiDeletionXss || null")).to be_nil
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)

      cancel = find_link("キャンセルして一覧へ戻る")
      cancel.send_keys(:enter)
      expect(page).to have_current_path(manage_admin_oshis_path(q: name))
      expect(target.reload).to be_persisted
      click_link "削除内容を確認"
      cancel = find_link("キャンセルして一覧へ戻る")
      cancel.send_keys(:tab)
      button = find("main button", text: "この推しマスタを削除", exact_text: true)
      expect(button.evaluate_script("this === document.activeElement")).to be(true)
      expect(button.evaluate_script("getComputedStyle(this).outlineStyle !== 'none' && parseFloat(getComputedStyle(this).outlineWidth) > 0")).to be(true)
      expect(button.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      if ENV["ADMIN_OSHI_DELETE_CAPTURE"] == "1"
        page.save_screenshot(Rails.root.join("tmp/admin-oshi-delete-20261102-confirm-#{width}.png"))
      end
      prompt = "「#{name}」の推しマスタを削除します。元には戻せません。実行しますか？"
      dismiss_confirm(prompt) { button.click }
      expect(target.reload).to be_persisted
      expect(page).to have_current_path(confirm_destroy_admin_oshi_path(target, q: name))
      accept_confirm(prompt) { button.send_keys(:enter) }
      expect(page).to have_current_path(manage_admin_oshis_path(q: name))
      expect(page).to have_css("[role='status']", text: "推しマスタ「#{name}」を削除しました。", exact_text: true)
      expect(Oshi.exists?(target.id)).to be(false)

      fill_in "名前・別名・所属・作品で検索", with: used.name
      click_button "検索"
      click_link "削除内容を確認"
      expect(page).to have_text("個人の登録・個人写真")
      expect(page).not_to have_css("main button", text: "この推しマスタを削除", exact_text: true)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(personal.reload.representative_image.download).to eq(bytes)
      expect(used.reload).to be_persisted
    end
  end
end
