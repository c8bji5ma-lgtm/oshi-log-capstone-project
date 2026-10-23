require "rails_helper"

RSpec.describe "Activity summary drilldown in the browser", type: :system do
  it "opens a visible filtered list and returns to the summary at mobile and desktop widths" do
    user = create(:user)
    registration = create(:user_oshi, user: user)
    registration.oshi.update!(name: "長い推し名" + ("あ" * 30))
    activity = build(:activity, :without_oshis, user: user, title: "ドリルダウン対象", occurred_on: Date.current)
    Activities::Save.call(activity: activity, oshi_ids: [ registration.oshi_id ])
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"

    [ [ 375, 812, "mobile" ], [ 1280, 900, "desktop" ] ].each do |width, height, label|
      page.current_window.resize_to(width, height)
      visit oshi_data_path
      link = find("a", exact_text: "1回", match: :first)
      link.send_keys(:enter)
      expect(page).to have_css("#activity-filter-summary", text: "適用中の条件")
      expect(page).to have_link("ドリルダウン対象")
      expect(page).to have_link("推し活データへ戻る")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      save_screenshot(Rails.root.join("tmp/issue90/#{label}.png"))
    end
  end
end
