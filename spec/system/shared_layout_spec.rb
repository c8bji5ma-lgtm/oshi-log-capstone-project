require "rails_helper"

RSpec.describe "Shared header and footer layout", type: :system do
  def check_layout(name, width, short: false)
    expect(page).to have_css("body > header.site-header", count: 1)
    expect(page).to have_css("body > main", count: 1)
    expect(page).to have_css("body > footer.site-footer", count: 1)
    within("body > footer") do
      expect(page).to have_text("OshiLog｜推し活を記録し、振り返るサービス")
      expect(page).to have_link("トップページへ戻る", href: root_path)
    end
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const rect = selector => {
          const r = document.querySelector(selector).getBoundingClientRect();
          return {top: r.top + window.scrollY, bottom: r.bottom + window.scrollY};
        };
        return {
          header: rect('body > header'), main: rect('body > main'), footer: rect('body > footer'),
          viewport: window.innerHeight, height: document.documentElement.scrollHeight,
          overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth
        };
      })()
    JS
    expect(geometry["header"]["top"]).to eq(0)
    expect(geometry["header"]["bottom"]).to be <= geometry["main"]["top"]
    expect(geometry["main"]["bottom"]).to be <= geometry["footer"]["top"]
    expect(geometry["footer"]["bottom"]).to be_within(1).of(geometry["height"])
    expect(geometry["overflow"]).to be(false)
    expect(geometry["footer"]["bottom"]).to be_within(1).of(geometry["viewport"]) if short
    directory = Rails.root.join("tmp/issue112")
    FileUtils.mkdir_p(directory)
    page.save_screenshot(directory.join("#{name}-#{width}.png"))
    page.execute_script("arguments[0].scrollIntoView({block: 'end'})", find("body > footer"))
    page.save_screenshot(directory.join("#{name}-footer-#{width}.png"))
  end

  it "places the public top and short login page footer below the content at both widths" do
    [ 375, 1280 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit root_path
      expect(page).to have_css("main h1", text: "推し活の記録を、振り返る楽しみに。", exact_text: true)
      check_layout("top", width)
      visit new_user_session_path
      expect(page).to have_button("ログイン")
      check_layout("login", width, short: true)
      within("footer") { click_link "トップページへ戻る" }
      expect(page).to have_current_path(root_path)
    end
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  it "keeps the signed-in short page and long activity history in normal document flow" do
    user = create(:user)
    oshi = create(:user_oshi, user: user).oshi
    12.times do |index|
      create(:activity, :without_oshis, user: user, oshis: [ oshi ], title: "配置確認の活動#{index}", occurred_on: Date.current)
    end
    visit new_user_session_path
    within("main form") do
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
    end
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    [ 375, 1280 ].each do |width|
      # At 375px the existing navigation and my-page links need a taller viewport
      # to exercise a genuinely short page rather than overflowing content.
      page.current_window.resize_to(width, 1600)
      visit my_page_path
      expect(page).to have_css("main h1", text: "マイページ", exact_text: true)
      check_layout("my-page", width, short: true)
      page.current_window.resize_to(width, 900)
      visit activities_path
      expect(page).to have_css(".activity-entry", count: 12)
      expect(page.evaluate_script("document.documentElement.scrollHeight > window.innerHeight")).to be(true)
      check_layout("history", width)
    end
  ensure
    page.current_window.resize_to(1280, 1024)
  end
end
