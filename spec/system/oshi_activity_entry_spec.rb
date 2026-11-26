require "rails_helper"

RSpec.describe "Activity entry from a personal oshi on mobile", type: :system do
  it "opens the preselected form and the filtered history without horizontal overflow" do
    user = create(:user)
    registration = create(:user_oshi, user: user)
    another = create(:user_oshi, user: user)
    activity = build(:activity, :without_oshis, user: user, title: "ライブの思い出")
    Activities::Save.call(activity: activity, oshi_ids: [ registration.oshi_id ])

    page.current_window.resize_to(375, 812)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit user_oshi_path(registration)

    expect(page).to have_link("この推しの活動を記録")
    expect(page).to have_link(activity.title)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
    click_link "この推しの活動を記録"
    expect(page).to have_checked_field("activity_oshi_ids_#{registration.oshi_id}", visible: :all)
    expect(page).to have_unchecked_field("activity_oshi_ids_#{another.oshi_id}", visible: :all)

    visit user_oshi_path(registration)
    click_link "この推しの活動をすべて見る"
    expect(page).to have_link(activity.title)
    expect(page).to have_css("#activity-filter-summary", text: "適用中の条件")
  end
end
