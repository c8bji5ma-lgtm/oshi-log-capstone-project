require "rails_helper"

RSpec.describe "Activity records and visualization in the browser", type: :system do
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "活動の推しA") }
  let(:second_oshi) { create(:oshi, :approved, name: "活動の推しB") }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second_oshi)
  end

  def recorded_activity(oshi:, **attributes)
    activity = build(:activity, :without_oshis, user: user, **attributes)
    activity.activity_oshis.build(oshi: oshi)
    activity.save!
    activity
  end

  def sign_in
    visit new_user_session_path
    within("main form") do
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "Log in"
    end
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def open_activity_list
    within("nav[aria-label='グローバルナビゲーション']") { click_link "活動記録一覧" }
    expect(page).to have_css("main h1", text: "活動記録一覧", exact_text: true)
  end

  def open_data
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    click_link "推し活データを見る"
    expect(page).to have_css("main h1", text: "推し活データ", exact_text: true)
  end

  def check_data(year:, oshi:, count:, amount:)
    within("form.data-filter") do
      select "#{year}年", from: "期間"
      select oshi.name, from: "推し"
      click_button "表示する"
    end
    expect(page).to have_css(".data-period", text: "#{year}年1月1日〜#{year}年12月31日の活動（#{oshi.name}）", exact_text: true)
    expect(page).to have_css("#activity-count", text: "#{count}回", exact_text: true)
    expect(page).to have_css("#activity-amount", text: amount, exact_text: true)
  end

  it "records, filters and edits an activity and updates year and oshi aggregates" do
    previous = recorded_activity(oshi: oshi, title: "比較用の前年記録", occurred_on: Date.new(2024, 5, 10), amount: 700)
    sign_in
    open_activity_list
    click_link "記録する", exact: true
    expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
    within("main form") do
      check oshi.name, allow_label_click: true
      fill_in "活動日（必須）", with: Date.new(2025, 5, 10)
      select "ライブ・イベント", from: "カテゴリ（必須）"
      fill_in "タイトル（必須）", with: "福岡ライブの思い出"
      fill_in "場所", with: "福岡"
      fill_in "金額（円）", with: "1000"
      fill_in "メモ", with: "初めて参加した公演"
      click_button "記録する"
    end
    expect(page).to have_css("[role='status']", text: "活動記録を登録しました。")
    expect(page).to have_link("福岡ライブの思い出")
    expect(page).to have_link(previous.title)

    within("form.activity-filter") do
      select oshi.name, from: "推し"
      select "ライブ・イベント", from: "カテゴリ"
      fill_in "キーワード", with: "福岡ライブ"
      click_button "絞り込む"
    end
    expect(page).to have_css(".activity-list a", text: "福岡ライブの思い出", exact_text: true)
    expect(page).to have_css(".activity-list a", count: 1)
    expect(page).not_to have_link(previous.title)

    open_data
    check_data(year: 2025, oshi: oshi, count: 1, amount: "1,000円")
    check_data(year: 2024, oshi: oshi, count: 1, amount: "700円")

    open_activity_list
    click_link "福岡ライブの思い出", exact: true
    expect(page).to have_css("main h1", text: "活動記録の詳細", exact_text: true)
    click_link "編集", exact: true
    expect(page).to have_css("main h1", text: "活動記録を編集", exact_text: true)
    within("main form") do
      expect(page).to have_field("タイトル（必須）", with: "福岡ライブの思い出")
      uncheck oshi.name, allow_label_click: true
      check second_oshi.name, allow_label_click: true
      fill_in "活動日（必須）", with: Date.new(2025, 6, 12)
      select "配信視聴", from: "カテゴリ（必須）"
      fill_in "タイトル（必須）", with: "見直した配信の記録"
      fill_in "金額（円）", with: "2500"
      fill_in "メモ", with: "編集後の感想"
      click_button "更新する"
    end
    expect(page).to have_css("[role='status']", text: "活動記録を更新しました。")
    expect(page).to have_css("main h2", text: "見直した配信の記録", exact_text: true)
    within("main") do
      expect(page).to have_css("dd", text: second_oshi.name, exact_text: true)
      expect(page).to have_css("dd", text: "2025/06/12", exact_text: true)
      expect(page).to have_css(".activity-memo", text: "編集後の感想", exact_text: true)
    end
    open_activity_list
    expect(page).to have_link("見直した配信の記録")
    expect(page).not_to have_link("福岡ライブの思い出")

    open_data
    check_data(year: 2025, oshi: oshi, count: 0, amount: "支出記録なし")
    check_data(year: 2025, oshi: second_oshi, count: 1, amount: "2,500円")
    within(".monthly-bars li", text: "6月") do
      expect(page).to have_css(".data-bar-value", text: "1回", exact_text: true)
    end
  end

  it "shows a conflict without overwriting a newer activity edit" do
    activity = recorded_activity(oshi: oshi, title: "編集前", occurred_on: Date.new(2025, 5, 10), amount: 500)
    sign_in
    open_activity_list
    click_link activity.title, exact: true
    click_link "編集", exact: true
    stale_version = find("input[name='activity[lock_version]']", visible: false).value
    Activity.find(activity.id).update!(title: "別画面の更新", amount: 700)

    fill_in "タイトル（必須）", with: "古い画面の入力"
    fill_in "金額（円）", with: "900"
    click_button "更新する"

    expect(page).to have_css(".validation-errors", text: "別の画面で更新")
    expect(page).to have_css(".conflict-summary", text: "別画面の更新")
    expect(page).to have_field("タイトル（必須）", with: "古い画面の入力")
    expect(find("input[name='activity[lock_version]']", visible: false).value).to eq(stale_version)
    expect(page).to have_link("最新内容で編集し直す", href: edit_activity_path(activity))
    expect(activity.reload).to have_attributes(title: "別画面の更新", amount: 700)
  end

  it "keeps an activity when deletion is cancelled and updates the list and aggregates after confirmation" do
    retained = recorded_activity(oshi: oshi, title: "残す活動記録", occurred_on: Date.new(2025, 5, 10), amount: 500)
    deleted = recorded_activity(oshi: second_oshi, title: "削除する活動記録", occurred_on: Date.new(2025, 6, 12), amount: 2500)
    sign_in
    open_data
    check_data(year: 2025, oshi: second_oshi, count: 1, amount: "2,500円")

    click_link "活動記録一覧を見る"
    click_link deleted.title, exact: true
    expect(page).to have_css("main h1", text: "活動記録の詳細", exact_text: true)
    dismiss_confirm("この活動記録を削除しますか？") { click_button "削除", exact: true }
    expect(page).to have_current_path(activity_path(deleted))
    expect(page).to have_css("main h2", text: deleted.title, exact_text: true)

    open_data
    check_data(year: 2025, oshi: second_oshi, count: 1, amount: "2,500円")
    click_link "活動記録一覧を見る"
    expect(page).to have_link(deleted.title)
    click_link deleted.title, exact: true
    accept_confirm("この活動記録を削除しますか？") { click_button "削除", exact: true }
    expect(page).to have_current_path(activities_path)
    expect(page).to have_css("[role='status']", text: "活動記録を削除しました。")
    expect(page).not_to have_link(deleted.title)
    expect(page).to have_link(retained.title)

    open_data
    check_data(year: 2025, oshi: second_oshi, count: 0, amount: "支出記録なし")
    check_data(year: 2025, oshi: oshi, count: 1, amount: "500円")
  end
end
