require "rails_helper"

RSpec.describe "Activity filter controls in the browser", type: :system do
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "記録を振り返る推し") }
  let(:query) { "  日本語 +%2F & 記録  " }
  let!(:registration) { create(:user_oshi, user: user, oshi: oshi) }
  let!(:matching) { create(:activity, :without_oshis, user: user, oshis: [ oshi ], title: "条件に合う思い出", occurred_on: Date.current, memo: query) }
  let!(:other) { create(:activity, :without_oshis, user: user, oshis: [ oshi ], title: "もう一つの思い出", occurred_on: Date.current - 1) }

  before do
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def expect_expanded(value)
    nodes = page.driver.browser.execute_cdp("Accessibility.getFullAXTree").fetch("nodes")
    node = nodes.find do |item|
      item.dig("name", "value") == "絞り込み条件を変更" &&
        item.fetch("properties", []).any? { |property| property["name"] == "expanded" }
    end
    expect(node).to be_present
    expanded = node.fetch("properties").find { |property| property["name"] == "expanded" }
    expect(expanded.dig("value", "value")).to eq(value)
  end

  [ 375, 1280 ].each do |width|
    it "keeps records reachable and preserves draft filters through keyboard opening, applying and clearing at #{width}px" do
      page.current_window.resize_to(width, 900)
      visit activities_path
      expect(page).not_to have_css("form.activity-filter")
      expect_expanded(false)
      expect(page.evaluate_script("document.querySelector('.activity-entry').getBoundingClientRect().top < innerHeight")).to be(true)

      url = page.current_url
      summary = find(".activity-filter-panel > summary")
      scroll_before = page.evaluate_script("scrollY")
      summary.send_keys(:enter)
      expect(page.evaluate_script("document.activeElement.tagName")).to eq("SUMMARY")
      expect(page.evaluate_script("scrollY")).to eq(scroll_before)
      expect(page).to have_css("form.activity-filter")
      expect_expanded(true)
      expect(page.evaluate_script("getComputedStyle(document.activeElement).outlineStyle")).not_to eq("none")
      find("#oshi_id").send_keys(:end)
      fill_in "q", with: query
      summary.click
      expect(page).not_to have_css("form.activity-filter")
      expect(page.current_url).to eq(url)
      expect(page).to have_link(matching.title)
      expect(page).to have_link(other.title)

      summary.send_keys(:space)
      expect_expanded(true)
      expect(page).to have_field("q", with: query)
      expect(page).to have_select("oshi_id", selected: oshi.name)
      find("form.activity-filter input[type='submit']").send_keys(:enter)
      expect(page).to have_link(matching.title)
      expect(page).not_to have_link(other.title)
      expect(page).not_to have_css("form.activity-filter")
      expect(Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)["q"]).to eq(query)
      expect(page).to have_css("#activity-filter-summary", text: "適用中の条件")
      expect(page).to have_link("条件を解除する", href: activities_path)

      find_link("条件を解除する").send_keys(:enter)
      expect(page).to have_current_path(activities_path)
      expect(page).to have_link(matching.title)
      expect(page).to have_link(other.title)
      expect(page).not_to have_css("#activity-filter-summary")
    ensure
      page.current_window.resize_to(1280, 1024)
    end

    it "shows direct-URL bounds and restores every existing field when conditions are reopened at #{width}px" do
      page.current_window.resize_to(width, 900)
      period = width == 375 ? { year: Date.current.year.to_s } : { month: Date.current.strftime("%Y-%m") }
      filters = period.merge(through: Date.current.iso8601, oshi_id: oshi.id.to_s, activity_type: matching.activity_type, q: query)
      visit activities_path(filters)
      expect(page).to have_link(matching.title)
      expect(page).not_to have_css("form.activity-filter")
      expect(page).to have_text("対象日の上限: #{Date.current.iso8601}（当日を含む）")
      find(".activity-filter-panel > summary").send_keys(:enter)
      expect(page).to have_field("month", with: period[:month].to_s)
      expect(page).to have_field("q", with: query)
      expect(page).to have_select("oshi_id", selected: oshi.name)
      expect(page).to have_select("activity_type", selected: matching.activity_type)
      expect(find("input[name='through']", visible: :all).value).to eq(filters[:through])
      expect(find("input[name='year']", visible: :all).value).to eq(period[:year]) if period[:year]

      visit activities_path(through: (Date.current - 1).iso8601)
      expect(page).to have_link(other.title)
      expect(page).not_to have_link(matching.title)
      expect(page).to have_text("対象日の上限: #{(Date.current - 1).iso8601}（当日を含む）")
      find_link("条件を解除する").send_keys(:enter)
      expect(page).to have_link(matching.title)
    ensure
      page.current_window.resize_to(1280, 1024)
    end
  end

  it "keeps invalid conditions and recovery visible without showing any records" do
    [
      { year: Date.current.year.to_s, month: Date.current.strftime("%Y-%m"), q: query },
      { through: "2026-13-99", q: query }
    ].each do |filters|
      visit activities_path(filters)
      expect(page).to have_css("#activity-filter-errors[role='alert']")
      expect(page).to have_css("#activity-filter-summary", text: "指定した条件", exact_text: true)
      expect(page).to have_css("form.activity-filter")
      expect_expanded(true)
      expect(page).to have_field("q", with: query)
      expect(page).not_to have_link(matching.title)
      expect(page).not_to have_link(other.title)
      within("form.activity-filter") { find_link("条件をクリア").send_keys(:enter) }
      expect(page).to have_link(matching.title)
      expect(page).not_to have_css("#activity-filter-errors")
    end
  end

  it "keeps controls usable with long names at 320px and enlarged text" do
    oshi.update!(name: "長い日本語の推し名でも毎日の思い出を大切に記録する")
    [ [ 320, "100%" ], [ 375, "200%" ] ].each do |width, scale|
      page.current_window.resize_to(width, 900)
      visit activities_path
      page.execute_script("document.documentElement.style.fontSize = arguments[0]", scale)
      find(".activity-filter-panel > summary").send_keys(:enter)
      expect(page).to have_css("form.activity-filter")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      fill_in "q", with: "長い日本語の検索条件でも入力できます"
      expect(page).to have_field("q", with: "長い日本語の検索条件でも入力できます")
    end
  ensure
    page.execute_script("document.documentElement.style.fontSize = ''")
    page.current_window.resize_to(1280, 1024)
  end
end
