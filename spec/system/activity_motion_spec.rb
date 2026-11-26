require "rails_helper"

RSpec.describe "Feedback while recording an activity", type: :system do
  let(:user) { create(:user) }
  let!(:registration) { create(:user_oshi, user: user) }

  before do
    page.current_window.resize_to(375, 812)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit activities_path
  end

  def watch_transitions
    page.execute_script(<<~JS)
      window.activityTransitionCount = 0
      const start = document.startViewTransition?.bind(document)
      if (start) document.startViewTransition = (...args) => {
        window.activityTransitionCount += 1
        return start(...args)
      }
    JS
  end

  def record_activity
    check registration.oshi.name, allow_label_click: true
    select "ライブ・イベント", from: "カテゴリ（必須）"
    fill_in "タイトル（必須）", with: "活動を記録するテスト"
    click_button "記録する"
  end

  it "uses keyboard navigation, celebrates once on success and does not replay on back" do
    watch_transitions
    find("a.activity-press", exact_text: "記録する").send_keys(:enter)
    expect(page).to have_current_path(new_activity_path)
    expect(page).to have_button("記録する")
    if page.evaluate_script("typeof document.startViewTransition === 'function' && !matchMedia('(prefers-reduced-motion: reduce)').matches")
      expect(page.evaluate_script("window.activityTransitionCount")).to eq(1)
    end
    record_activity
    expect(page).to have_css(".activity-recorded-notice[role='status'][data-turbo-temporary]", text: "活動記録を登録しました。")
    expect(page).to have_css(".activity-recorded-mark[aria-hidden='true']")
    click_link "活動を記録するテスト"
    expect(page).to have_no_css(".activity-recorded-notice")
    go_back
    expect(page).to have_current_path(activities_path)
    expect(page).to have_no_css(".activity-recorded-notice")
  end

  it "keeps the success text but skips animations when reduced motion is enabled" do
    browser = page.driver.browser
    browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    begin
      watch_transitions
      click_link "記録する", exact: true
      expect(page).to have_current_path(new_activity_path)
      record_activity
      expect(page).to have_css(".activity-recorded-notice", text: "活動記録を登録しました。")
      expect(page.evaluate_script("getComputedStyle(document.querySelector('.activity-recorded-mark')).animationName")).to eq("none")
      expect(page.evaluate_script("window.activityTransitionCount")).to eq(0)
    ensure
      browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    end
  end

  it "does not celebrate a failed save" do
    click_link "記録する", exact: true
    expect(page).to have_current_path(new_activity_path)
    select "ライブ・イベント", from: "カテゴリ（必須）"
    fill_in "タイトル（必須）", with: "推しが未選択の記録"
    click_button "記録する"
    expect(page).to have_css(".validation-errors", text: "推し")
    expect(page).to have_no_css(".activity-recorded-notice")
  end
end
