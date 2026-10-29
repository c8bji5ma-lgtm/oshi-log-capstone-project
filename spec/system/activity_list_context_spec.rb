require "rails_helper"

RSpec.describe "Activity list return navigation", type: :system do
  [ 375, 1280 ].each do |width|
    it "keeps each tab's filters and keyboard return at #{width}px" do
      user = create(:user)
      oshi = create(:oshi, :approved)
      create(:user_oshi, user: user, oshi: oshi)
      keyword = "  日本語 +%2F &<記録>  "
      first = build(:activity, :without_oshis, user: user, title: "観測対象A", occurred_on: "2025-05-10", memo: keyword)
      second = build(:activity, :without_oshis, user: user, title: "観測対象B", occurred_on: "2025-05-11", memo: "変更後 B")
      [ first, second ].each { |activity| Activities::Save.call(activity: activity, oshi_ids: [ oshi.id ]) }
      originals = [ first, second ].map(&:attributes)
      page.current_window.resize_to(width, 900)
      visit new_user_session_path
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
      expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
      filters = { month: "2025-05", oshi_id: oshi.id, activity_type: first.activity_type, q: keyword, through: "2025-05-20" }
      visit activities_path(filters)
      expect(page).to have_link("観測対象A")
      expect(page).not_to have_link("観測対象B")
      find(".activity-list a", text: "観測対象A").send_keys(:enter)
      expect(page).to have_css("main h1", exact_text: "活動記録の詳細")
      first_detail_url = page.current_url
      capture_context(width, "detail")
      find_link("活動記録一覧へ戻る").send_keys(:enter)
      expect(page).to have_field("q", with: keyword)
      expect(page).to have_select("oshi_id", selected: oshi.name)
      expect(page).to have_field("month", with: "2025-05")
      expect(find("input[name='through']", visible: :all).value).to eq("2025-05-20")
      expect(page).to have_link("観測対象A")
      expect(page).not_to have_link("観測対象B")
      capture_context(width, "returned")

      fill_in "q", with: "変更後 B"
      find("form.activity-filter input[type='submit']").click
      expect(page).to have_link("観測対象B")
      expect(page).not_to have_link("観測対象A")
      click_link "観測対象B"
      expect(page).to have_css("main h2", exact_text: "観測対象B")
      second_window = open_new_window
      within_window(second_window) do
        visit first_detail_url
        expect(page).to have_css("main h2", exact_text: "観測対象A")
        click_link "活動記録一覧へ戻る"
        expect(page).to have_field("q", with: keyword)
        expect(page).to have_link("観測対象A")
        expect(page).not_to have_link("観測対象B")
      end
      second_window.close
      click_link "活動記録一覧へ戻る"
      expect(page).to have_field("q", with: "変更後 B")
      expect(page).to have_link("観測対象B")
      expect(page).not_to have_link("観測対象A")

      visit activity_path(first)
      click_link "活動記録一覧へ戻る"
      expect(page).to have_field("q", with: "")
      expect(page).to have_link("観測対象A")
      expect(page).to have_link("観測対象B")
      expect([ first, second ].map { |activity| activity.reload.attributes }).to eq(originals)
    end
  end

  def capture_context(width, phase)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    browser = page.driver.browser
    size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
    directory = Rails.root.join("tmp/h01-ui", ENV.fetch("H01_CAPTURE_LABEL", "initial"))
    FileUtils.mkdir_p(directory)
    path = directory.join("#{width}-#{phase}.png")
    File.binwrite(path, Base64.strict_decode64(shot.fetch("data")))
    record = {
      query: Rack::Utils.parse_nested_query(URI.parse(page.current_url).query),
      back_href: page.has_link?("活動記録一覧へ戻る", wait: 0) ? find_link("活動記録一覧へ戻る")[:href] : nil,
      keyword: page.has_css?("input[name='q']", wait: 0) ? find("input[name='q']").value : nil,
      viewport_width: page.evaluate_script("innerWidth"),
      scroll_width: page.evaluate_script("document.documentElement.scrollWidth"),
      screenshot: path.to_s
    }
    File.write(directory.join("#{width}-#{phase}.json"), JSON.pretty_generate(record))
  end
end
