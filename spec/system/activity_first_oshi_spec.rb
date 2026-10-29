require "rails_helper"
require_relative "../support/started_period_picker"

RSpec.describe "Activity entry before the first oshi", type: :system do
  include StartedPeriodPicker
  let(:user) { create(:user) }

  def sign_in
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def open_activity_entry
    within("nav[aria-label='グローバルナビゲーション']") { click_link "活動記録一覧" }
    expect(page).to have_css("main h1", text: "活動記録一覧", exact_text: true)
    within("main") { click_link "記録する", exact: true }
    expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
    expect(page).to have_text("先に推しを登録してください。")
    expect(page).not_to have_field("タイトル（必須）")
    expect(page).not_to have_css("#activity_images")
  end

  def open_oshi_registration
    find_link("推しを登録", exact: true).send_keys(:enter)
    expect(page).to have_current_path(new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION))
    expect(page).to have_css("main h1", text: "推し登録", exact_text: true)
  end

  [ 375, 1280 ].each do |width|
    it "registers the prerequisite before starting activity input at #{width}px" do
      sign_in
      page.current_window.resize_to(width, 900)
      open_activity_entry
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      open_oshi_registration
      name = "活動入口からの推し#{width}"
      within("form[action='#{oshis_path}']") do
        fill_in "推し名（必須）", with: name
        select "アイドル", from: "種別（必須）"
        select_started_period "2020/05"
        click_button "新しい推しを登録", exact: true
      end

      expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
      registered = user.user_oshis.sole
      expect(page).to have_current_path(new_activity_path(initial_oshi_id: registered.oshi_id))
      expect(page).to have_checked_field(name, visible: :all)
      expect(registered.started_period).to eq("2020/05")
      expect(user.activities).to be_empty

      fill_in "活動日（必須）", with: Date.new(2025, 12, 12)
      select "ライブ・イベント", from: "カテゴリ（必須）"
      fill_in "タイトル（必須）", with: "推し登録後の初記録#{width}"
      fill_in "場所", with: "登録後の会場"
      fill_in "金額（円）", with: "1200"
      fill_in "メモ", with: "登録後に入力したメモ"
      attach_file "画像（複数可）", Rails.root.join("spec/fixtures/files/image.png")
      expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
      click_button "記録する", exact: true

      expect(page).to have_link("推し登録後の初記録#{width}")
      activity = user.activities.sole
      expect(activity).to have_attributes(occurred_on: Date.new(2025, 12, 12), place: "登録後の会場",
        amount: 1200, memo: "登録後に入力したメモ")
      expect(activity.oshi_ids).to eq([ registered.oshi_id ])
      expect(activity.images.sole.filename.to_s).to eq("image.png")
    end
  end

  it "returns an existing candidate to the activity form without creating a new oshi" do
    candidate = create(:oshi, :approved, name: "既存候補からの初記録")
    sign_in
    open_activity_entry
    open_oshi_registration
    fill_in "推しを検索", with: candidate.name
    click_button "検索", exact: true
    expect(page).to have_field(candidate.name, type: "radio", exact: false)
    count = Oshi.count
    within("form[action='#{user_oshis_path}']") do
      choose candidate.name, exact: false
      select_started_period "2018/03"
      click_button "選んだ推しを追加"
    end

    expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
    expect(page).to have_current_path(new_activity_path(initial_oshi_id: candidate.id))
    expect(page).to have_checked_field(candidate.name, visible: :all)
    expect(Oshi.count).to eq(count)
    expect(user.user_oshis.sole.started_period).to eq("2018/03")
    expect(user.activities).to be_empty
  end

  it "keeps the continuation and entered registration fields after a period error" do
    sign_in
    open_activity_entry
    open_oshi_registration
    within("form[action='#{oshis_path}']") do
      fill_in "推し名（必須）", with: "登録エラーからの復帰"
      select "声優", from: "種別（必須）"
      select_started_period "2020/13"
      click_button "新しい推しを登録", exact: true
    end
    expect(page).to have_css(".validation-errors[role='alert']")
    expect(page).to have_field("推し名（必須）", with: "登録エラーからの復帰")
    expect(page).to have_field("new_user_oshi_started_period", with: "2020/13", visible: :all)
    expect(user.user_oshis).to be_empty

    within("form[action='#{oshis_path}']") do
      select_started_period "2020/05"
      click_button "新しい推しを登録", exact: true
    end
    expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
    expect(page).to have_checked_field("登録エラーからの復帰", visible: :all)
  end
end
