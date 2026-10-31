require "rails_helper"

RSpec.describe "Profile validation copy", type: :system do
  let(:user) { create(:user) }

  it "renders Japanese display-name errors at both widths and saves only after correction" do
    profile = create(:profile, user: user, display_name: "保存済みの表示名", introduction: "保存済みの自己紹介")
    original = profile.attributes
    submitted = "  未保存の自己紹介\n次の行  "
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit edit_profile_path
    fill_in "表示名（必須）", with: " "
    fill_in "自己紹介", with: submitted
    click_button "プロフィールを保存"

    expect(page).to have_css(".validation-errors[role='alert'] li", exact_text: "表示名を入力してください")
    expect(page).not_to have_text("Display name")
    expect(page).to have_field("profile_display_name", with: " ")
    expect(page).to have_field("自己紹介", with: submitted)
    expect(profile.reload.attributes).to eq(original)

    [ 375, 1280 ].each do |width|
      page.current_window.resize_to(width, 900)
      expect(page).to have_css(".validation-errors[role='alert'] li", exact_text: "表示名を入力してください")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
      browser = page.driver.browser
      size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: [ size.fetch("width"), page.evaluate_script("innerWidth") ].max, height: size.fetch("height"), scale: 1 })
      directory = Rails.root.join("tmp/ux04-ui", ENV.fetch("UX04_CAPTURE_LABEL", "initial"))
      FileUtils.mkdir_p(directory)
      image_path = directory.join("#{width}-profile-error.png")
      File.binwrite(image_path, Base64.strict_decode64(shot.fetch("data")))
      record = {
        path: URI.parse(page.current_url).request_uri,
        error: find(".validation-errors[role='alert']").text,
        label: find("label[for='profile_display_name']").text,
        submitted_name: find("#profile_display_name").value,
        submitted_introduction: find("#profile_introduction").value,
        database_name: profile.reload.display_name,
        database_introduction: profile.introduction,
        viewport_width: page.evaluate_script("innerWidth"),
        scroll_width: page.evaluate_script("document.documentElement.scrollWidth"),
        screenshot: image_path.to_s
      }
      File.write(directory.join("#{width}-profile-error.json"), JSON.pretty_generate(record))
    end

    fill_in "表示名（必須）", with: "訂正した表示名"
    click_button "プロフィールを保存"
    expect(page).to have_css("[role='status']", text: "プロフィールを更新しました。")
    # The observed browser form sends textarea line breaks as CRLF.
    expected_posted = submitted.gsub("\n", "\r\n")
    expect(profile.reload).to have_attributes(display_name: "訂正した表示名", introduction: expected_posted)
    visit edit_profile_path
    expect(page).to have_field("自己紹介", with: submitted)
  end
end
