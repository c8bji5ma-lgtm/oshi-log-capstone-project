require "rails_helper"

RSpec.describe "User authentication in the browser", type: :system do
  let!(:user) { create(:user) }

  it "signs in through the login form and opens my page with the authenticated session" do
    visit new_user_session_path

    within("main form") do
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
    end

    expect(page).to have_current_path(root_path)
    expect(page).to have_css("main h1", text: "ホーム")

    within("nav[aria-label='グローバルナビゲーション']") do
      click_link "マイページ"
    end

    expect(page).to have_current_path(my_page_path)
    expect(page).to have_css("main h1", text: "マイページ")
    expect(page).to have_button("ログアウト")
  end

  it "shows an error for an incorrect password and keeps my page protected" do
    visit new_user_session_path

    within("main form") do
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "incorrect"
      click_button "ログイン"
    end

    expect(page).to have_css("[role='alert']", text: "メールアドレスまたはパスワードが正しくありません。")
    expect(page).to have_field("user_password")
    expect(page).not_to have_button("ログアウト")

    visit my_page_path

    expect(page).to have_current_path(new_user_session_path)
    expect(page).to have_css("[role='alert']", text: "続けるにはログインしてください。")
  end
end
