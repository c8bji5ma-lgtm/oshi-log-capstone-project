require "rails_helper"

RSpec.describe "Mobile activity form", type: :system do
  include_context "emotion master data"

  it "wraps many long choices without horizontal overflow" do
    user = create(:user)
    25.times do |index|
      registration = create(:user_oshi, user: user)
      registration.oshi.update!(name: "長い推し名#{index + 1}-#{'あ' * 40}")
    end
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit new_activity_path
    expect(page.all("input[type='checkbox']", visible: :all).size).to eq(32)

    [ [ 375, 812, "mobile" ], [ 1280, 900, "desktop" ] ].each do |width, height, label|
      page.current_window.resize_to(width, height)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      submit = find_button("記録する")
      page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", submit)
      expect(submit).to be_visible
      save_screenshot(Rails.root.join("tmp/issue89/#{label}.png"))
    end
  end
end
