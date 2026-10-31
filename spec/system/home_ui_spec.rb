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
    geometry = page.evaluate_script(<<~JS)
      (() => ({
        headerHeight: document.querySelector("body > header").getBoundingClientRect().height,
        firstRecordTop: document.querySelector(".home-recent-list li").getBoundingClientRect().top,
        summaryTop: document.querySelector(".home-summary-card").getBoundingClientRect().top,
        viewportHeight: innerHeight,
        dateRows: [...document.querySelectorAll(".home-recent-list time strong")].map(e => e.getBoundingClientRect().height / parseFloat(getComputedStyle(e).lineHeight)),
        targetHeights: [...document.querySelectorAll("header nav a, .nav-logout")].map(e => e.getBoundingClientRect().height)
      }))()
    JS
    expect(geometry["headerHeight"]).to be <= 116
    expect(geometry["firstRecordTop"]).to be < geometry["viewportHeight"]
    expect(geometry["firstRecordTop"]).to be < geometry["summaryTop"]
    expect(geometry["targetHeights"]).to all(be >= 44)
    expect(geometry["dateRows"]).to all(be <= 1.1)
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

  it "reflows the header at 320px and with enlarged text without splitting the wordmark" do
    [ [ 320, "100%" ], [ 375, "200%" ] ].each do |width, scale|
      page.current_window.resize_to(width, 900)
      visit root_path
      page.execute_script("document.documentElement.style.fontSize = arguments[0]", scale)
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const brand = document.querySelector(".site-brand"), style = getComputedStyle(brand);
          return {
            overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
            brandLines: brand.getBoundingClientRect().height / parseFloat(style.lineHeight)
          };
        })()
      JS
      expect(geometry["overflow"]).to be(false)
      expect(geometry["brandLines"]).to be <= 1.2
      expect(page).to have_css("header nav a", count: 4)
      expect(page).to have_button("ログアウト")
    end
  ensure
    page.execute_script("document.documentElement.style.fontSize = ''")
    page.current_window.resize_to(1280, 1024)
  end

  it "skips repeated navigation and keeps visible keyboard focus on the main action" do
    visit root_path
    page.find("body").send_keys(:tab)
    expect(page).to have_css(".skip-link:focus", text: "本文へ移動")
    expect(page.evaluate_script("getComputedStyle(document.activeElement).outlineStyle")).not_to eq("none")

    page.driver.browser.switch_to.active_element.send_keys(:enter)
    expect(page).to have_css("#main-content:focus")
    page.driver.browser.switch_to.active_element.send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("推し活を記録する")
    expect(page.evaluate_script("getComputedStyle(document.activeElement).outlineStyle")).not_to eq("none")
  end
end
