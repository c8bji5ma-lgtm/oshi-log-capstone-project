require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Oshi memory photos on a narrow screen", type: :system do
  include ImageAttachments

  it "renders a thumbnail at 320px and opens its original activity" do
    user = create(:user)
    registration = create(:user_oshi, user: user)
    activity = build(:activity, :without_oshis, user: user, title: "ライブの思い出")
    Activities::Save.call(activity: activity, oshi_ids: [ registration.oshi_id ])
    activity.images.attach(image_upload)

    window = page.current_window
    original_size = window.size
    window.resize_to(320, 812)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit user_oshi_path(registration)

    expect(page.evaluate_script("window.innerWidth")).to eq(320)
    within("section[aria-labelledby='oshi-memory-photos-heading']") do
      image = find("img")
      image.scroll_to(:center)
      expect(image).to match_selector(:css, "img") { |img| img.evaluate_script("this.complete && this.naturalWidth > 0") }
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      click_link activity.title
    end
    expect(page).to have_current_path(activity_path(activity))
    expect(page).to have_text(activity.title)
  ensure
    window.resize_to(*original_size) if original_size
  end
end
