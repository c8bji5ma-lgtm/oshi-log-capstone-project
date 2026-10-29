require "rails_helper"
require "tmpdir"
require_relative "../support/started_period_picker"

RSpec.describe "Started period selection in the browser", type: :system do
  include StartedPeriodPicker
  let(:user) { create(:user) }

  around do |example|
    old_services = ActiveStorage::Blob.services
    old_service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshi-period-", Rails.root.join("tmp")) do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      Capybara.reset_sessions!
    end
  ensure
    ActiveStorage::Blob.services = old_services
    ActiveStorage::Blob.service = old_service
  end

  def sign_in_at(width = 1280)
    @width = width
    page.current_window.resize_to(width, 900)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def period_root(id)
    find("[data-controller='oshi-period'][data-oshi-period-ready]", visible: :all) { |node| node.has_css?("##{id}", visible: :all) }
  end

  def expect_period(id, value)
    root = period_root(id)
    expect(root).to match_css("[data-oshi-period-ready='picker']")
    expect(root.find("[data-oshi-period-target='recover']", visible: :all)).not_to be_visible
    year, month = value.to_s.split("/")
    expect(find("##{id}", visible: :all).value).to eq(value.to_s)
    expect(find("##{id}_year").value).to eq(year.to_s)
    expect(find("##{id}_month").value).to eq(month.to_s)
    expect(find("##{id}_month").disabled?).to eq(year.blank?)
    text = year ? "#{year}年#{month ? "#{month.to_i}月" : ""}" : "未設定"
    expect(root).to have_css("[data-oshi-period-target='summary']", exact_text: "入力内容：#{text}")
  end

  def capture(name, id)
    root = period_root(id)
    rect = root.evaluate_script("(() => { const r=this.getBoundingClientRect(); return {top:r.top+scrollY,height:r.height}; })()")
    browser = page.driver.browser
    y = [ rect["top"] - 20, 0 ].max
    shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: y, width: page.evaluate_script("innerWidth"), height: rect["height"] + 40, scale: 1 })
    dir = Rails.root.join("tmp/started-period-ui/confirmed")
    FileUtils.mkdir_p(dir)
    image = dir.join("#{@width}-#{name}.png")
    File.binwrite(image, Base64.strict_decode64(shot.fetch("data")))
    state = { path: URI.parse(page.current_url).request_uri, source_id: id,
      source_value: find("##{id}", visible: :all).value, selected_year: find("##{id}_year").value,
      selected_month: find("##{id}_month").value, browsed_range: find("##{id}_range", visible: :all).value,
      visible_year: find("##{id}_year option:checked").text,
      summary: root.find("[data-oshi-period-target='summary']").text,
      max_year_options: root.all("[data-oshi-period-target='year'] option").size,
      viewport_width: page.evaluate_script("innerWidth"), scroll_width: page.evaluate_script("document.documentElement.scrollWidth"),
      active: page.evaluate_script("({id:document.activeElement.id,outline:getComputedStyle(document.activeElement).outline})"),
      screenshot: image.to_s }
    File.write(dir.join("#{@width}-#{name}.json"), JSON.pretty_generate(state))
  end

  [ 375, 1280 ].each do |width|
    it "selects an old year, keeps browsing separate, and recovers new registration at #{width}px" do
      sign_in_at(width)
      visit new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      within("form[action='#{oshis_path}']") do
        expect_period("new_user_oshi_started_period", "")
        expect(page).not_to have_select("new_user_oshi_started_period_range")
        find("#new_user_oshi_started_period_year").send_keys(:home, :arrow_down)
        expect_period("new_user_oshi_started_period", Date.current.year.to_s)
        select "#{Date.current.year - 40}年", from: "new_user_oshi_started_period_year"
        expect_period("new_user_oshi_started_period", (Date.current.year - 40).to_s)
        capture("new-recent", "new_user_oshi_started_period")
        select_started_period "1850/01"
        select "1851年", from: "new_user_oshi_started_period_year"
        expect_period("new_user_oshi_started_period", "1851/01")
        select "未設定", from: "new_user_oshi_started_period_month"
        expect_period("new_user_oshi_started_period", "1851")
        select_started_period ""
        expect_period("new_user_oshi_started_period", "")
        select_started_period "0000/01"
        expect_period("new_user_oshi_started_period", "0000/01")
        select_started_period "9999/12"
        expect_period("new_user_oshi_started_period", "9999/12")
        select_started_period "1850/12"
        select "1900〜1999年", from: "new_user_oshi_started_period_range"
        expect_period("new_user_oshi_started_period", "1850/12")
        expect(page).to have_select("new_user_oshi_started_period_year", selected: "1850年（選択中）")
        find("#new_user_oshi_started_period_year").send_keys(:tab)
        capture("new-browsing", "new_user_oshi_started_period")
        fill_in "推し名（必須）", with: " "
        select "アイドル", from: "種別（必須）"
        click_button "新しい推しを登録", exact: true
      end
      expect(page).to have_css(".validation-errors")
      expect(user.user_oshis).to be_empty
      within("form[action='#{oshis_path}']") do
        expect_period("new_user_oshi_started_period", "1850/12")
        capture("new-error", "new_user_oshi_started_period")
        fill_in "推し名（必須）", with: "選択登録#{width}"
        click_button "新しい推しを登録", exact: true
      end
      expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
      registered = user.user_oshis.sole
      expect(page).to have_current_path(new_activity_path(initial_oshi_id: registered.oshi_id))
      expect(registered.started_period).to eq("1850/12")
    end

    it "recovers an invalid candidate value and preserves the selected precision at #{width}px" do
      candidate = create(:oshi, :approved, name: "選択候補#{width}")
      sign_in_at(width)
      visit new_oshi_path(q: candidate.name, continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      within("form[action='#{user_oshis_path}']") do
        choose candidate.name, exact: false
        select_started_period "2020/13"
        click_button "選んだ推しを追加"
      end
      expect(page).to have_css(".validation-errors")
      expect(page).to have_field("existing_user_oshi_started_period", with: "2020/13")
      expect(page).to have_checked_field(candidate.name, exact: false)
      value = width == 375 ? "0000" : "9999/01"
      within("form[action='#{user_oshis_path}']") do
        select_started_period value
        expect_period("existing_user_oshi_started_period", value)
        capture("existing-recovered", "existing_user_oshi_started_period")
        click_button "選んだ推しを追加"
      end
      expect(page).to have_current_path(new_activity_path(initial_oshi_id: candidate.id))
      expect(user.user_oshis.sole.started_period).to eq(value)
    end

    it "retains edit selections through an unrelated error and explicitly clears them at #{width}px" do
      owned = create(:user_oshi, user: user, started_period: "1850/01", ended_period: "2025")
      sign_in_at(width)
      visit edit_user_oshi_path(owned)
      expect_period("user_oshi_started_period", "1850/01")
      select_started_period "1975/12"
      select "1976年", from: "user_oshi_started_period_year"
      find("details summary").click unless find("details").evaluate_script("this.open")
      expect(find("#user_oshi_started_period_range")).to be_visible
      select "2000〜2099年", from: "user_oshi_started_period_range"
      expect_period("user_oshi_started_period", "1976/12")
      fill_in "推し終了時期", with: "2025/13"
      click_button "推し情報を更新"
      expect(page).to have_css(".validation-errors")
      expect_period("user_oshi_started_period", "1976/12")
      expect(owned.reload.started_period).to eq("1850/01")
      capture("edit-error", "user_oshi_started_period")
      fill_in "推し終了時期", with: "2025"
      find("#user_oshi_started_period_year").send_keys(:home)
      expect_period("user_oshi_started_period", "")
      select_started_period "1800"
      find_button("推し始めをクリア").send_keys(:enter)
      expect_period("user_oshi_started_period", "")
      capture("edit-cleared", "user_oshi_started_period")
      click_button "推し情報を更新"
      expect(page).to have_css("[role='status']", text: "推し情報を更新しました")
      expect(owned.reload.started_period).to be_nil
      expect(owned.ended_period).to eq("2025")
    end
  end

  it "reconnects from the canonical value without duplicating fields or changing precision" do
    sign_in_at
    visit new_oshi_path
    within("form[action='#{oshis_path}']") { select_started_period "1750/12" }
    page.execute_script(<<~JS)
      window.periodDetached = document.querySelector("#new_user_oshi_started_period").closest("[data-controller='oshi-period']");
      window.periodParent = window.periodDetached.parentNode;
      window.periodDetached.remove();
    JS
    expect(page).not_to have_css("#new_user_oshi_started_period", visible: :all)
    page.execute_script("window.periodParent.appendChild(window.periodDetached)")
    expect_period("new_user_oshi_started_period", "1750/12")
    expect(page).to have_css("#new_user_oshi_started_period_year", count: 1)
  end

  it "submits the original text fallback when page JavaScript is unavailable" do
    sign_in_at
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit new_oshi_path
    within("form[action='#{oshis_path}']") do
      expect(page).to have_field("new_user_oshi_started_period")
      expect(page).not_to have_select("new_user_oshi_started_period_year")
      fill_in "推し名（必須）", with: "JSなしの登録"
      select "アイドル", from: "種別（必須）"
      fill_in "推し始め", with: "1750"
      click_button "新しい推しを登録", exact: true
    end
    expect(page).to have_css("[role='status']", text: "推しを登録しました")
    expect(user.user_oshis.sole.started_period).to eq("1750")
  ensure
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
  end
end
