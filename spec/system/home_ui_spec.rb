require "rails_helper"

RSpec.describe "Home and activity history presentation", type: :system do
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "きらめき推し") }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    activity = build(:activity, :without_oshis, user: user, title: "心に残ったライブ", occurred_on: Date.current, amount: 2400)
    activity.activity_oshis.build(oshi: oshi)
    activity.images.attach(io: File.open(Rails.root.join("spec/fixtures/files/image.jpg")), filename: "memory.jpg", content_type: "image/jpeg")
    activity.save!
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  it "keeps the data-led home and history usable at desktop and mobile widths" do
    directory = Rails.root.join("tmp/issue30")
    FileUtils.mkdir_p(directory)

    expect(page).to have_text("きらめき推し")
    expect(page).to have_text("心に残ったライブ")
    expect(page).to have_text("2,400円")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    page.save_screenshot(directory.join("home-1280.png"))

    page.current_window.resize_to(375, 812)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    expect(page).to have_link("推し活を記録する")
    page.save_screenshot(directory.join("home-375.png"))
    page.execute_script("arguments[0].scrollIntoView({block: 'start', behavior: 'instant'})", find(".home-recent-card"))
    page.save_screenshot(directory.join("home-content-375.png"))

    click_link "活動記録一覧", match: :first
    expect(page).to have_css(".activity-entry", text: "心に残ったライブ")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    page.execute_script("arguments[0].scrollIntoView({block: 'center', behavior: 'instant'})", find(".activity-entry"))
    page.save_screenshot(directory.join("activities-375.png"))
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  it "exposes keyboard focus while moving through the global navigation" do
    page.find("body").send_keys(:tab)
    focused = page.evaluate_script("document.activeElement && document.activeElement.textContent.trim()")
    expect(focused).to be_present
    expect(page.evaluate_script("getComputedStyle(document.activeElement).outlineStyle")).not_to eq("none")
  end
end
