require "rails_helper"

RSpec.describe "Fixed costs and visualization in the browser", type: :system do
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "固定費の推しA") }
  let(:second_oshi) { create(:oshi, :approved, name: "固定費の推しB") }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second_oshi)
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

  def open_data
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    click_link "推し活データを見る"
    expect(page).to have_css("main h1", text: "推し活データ", exact_text: true)
  end

  def open_fixed_costs
    click_link "固定費を管理する"
    expect(page).to have_css("main h1", text: "固定費一覧", exact_text: true)
  end

  def check_fixed_costs(monthly:, yearly:)
    expect(page).to have_css("#monthly-fixed-cost", text: monthly, exact_text: true)
    expect(page).to have_css("#yearly-fixed-cost", text: yearly, exact_text: true)
  end

  def check_subscription(name:, amount:, cycle:, oshi_name:)
    within("main section.card", text: name) do
      expect(page).to have_css("h2", text: name, exact_text: true)
      expect(page).to have_css("dd", text: amount, exact_text: true)
      expect(page).to have_css("dd", text: cycle, exact_text: true)
      expect(page).to have_css("dd", text: oshi_name, exact_text: true)
    end
  end

  def edit_subscription(name)
    within("main section.card", text: name) { click_link "編集", exact: true }
    expect(page).to have_css("main h1", text: "固定費を編集", exact_text: true)
  end

  it "registers and edits a fixed cost, changes and clears its oshis and refreshes visualization" do
    sign_in
    open_data
    check_fixed_costs(monthly: "0円", yearly: "0円")
    open_fixed_costs
    click_link "固定費を登録する"
    expect(page).to have_css("main h1", text: "固定費を登録", exact_text: true)
    within("main form") do
      fill_in "契約名（必須）", with: "ファンクラブ会費"
      fill_in "金額（円・必須）", with: "1000"
      select "月額", from: "請求周期（必須）"
      select oshi.name, from: "対象の推し（任意）"
      fill_in "開始日（任意）", with: Date.new(2024, 1, 1)
      click_button "登録する", exact: true
    end
    expect(page).to have_css("[role='status']", text: "固定費を登録しました。")
    check_subscription(name: "ファンクラブ会費", amount: "1,000円", cycle: "月額", oshi_name: oshi.name)
    open_data
    check_fixed_costs(monthly: "1,000円", yearly: "0円")

    open_fixed_costs
    edit_subscription("ファンクラブ会費")
    within("main form") do
      expect(page).to have_field("契約名（必須）", with: "ファンクラブ会費")
      expect(page).to have_select("対象の推し（任意）", selected: [ oshi.name ])
      fill_in "契約名（必須）", with: "更新した年会費"
      fill_in "金額（円・必須）", with: "2400"
      select "年額", from: "請求周期（必須）"
      unselect oshi.name, from: "対象の推し（任意）"
      select second_oshi.name, from: "対象の推し（任意）"
      click_button "更新する"
    end
    expect(page).to have_css("[role='status']", text: "固定費を更新しました。")
    expect(page).not_to have_css("main h2", text: "ファンクラブ会費", exact_text: true)
    check_subscription(name: "更新した年会費", amount: "2,400円", cycle: "年額", oshi_name: second_oshi.name)
    open_data
    check_fixed_costs(monthly: "0円", yearly: "2,400円")

    open_fixed_costs
    edit_subscription("更新した年会費")
    within("main form") do
      expect(page).to have_select("対象の推し（任意）", selected: [ second_oshi.name ])
      unselect second_oshi.name, from: "対象の推し（任意）"
      click_button "更新する"
    end
    expect(page).to have_css("[role='status']", text: "固定費を更新しました。")
    check_subscription(name: "更新した年会費", amount: "2,400円", cycle: "年額", oshi_name: "指定なし")
    edit_subscription("更新した年会費")
    expect(page).to have_select("対象の推し（任意）", selected: [])
    open_data
    check_fixed_costs(monthly: "0円", yearly: "2,400円")
  end

  it "shows a conflict without overwriting a newer fixed-cost edit" do
    record = create(:subscription, user: user, name: "編集前", amount: 500, oshis: [ oshi ])
    sign_in
    open_data
    open_fixed_costs
    edit_subscription(record.name)
    stale_version = find("input[name='subscription[lock_version]']", visible: false).value
    Subscription.find(record.id).update!(name: "別画面の更新", amount: 700)

    fill_in "契約名（必須）", with: "古い画面の入力"
    fill_in "金額（円・必須）", with: "900"
    click_button "更新する"

    expect(page).to have_css(".validation-errors", text: "別の画面で更新")
    expect(page).to have_css(".conflict-summary", text: "別画面の更新")
    expect(page).to have_field("契約名（必須）", with: "古い画面の入力")
    expect(find("input[name='subscription[lock_version]']", visible: false).value).to eq(stale_version)
    expect(page).to have_link("最新内容で編集し直す", href: edit_subscription_path(record))
    expect(record.reload).to have_attributes(name: "別画面の更新", amount: 700)
  end

  it "keeps a cancelled deletion and removes only the confirmed fixed cost from the list and visualization" do
    monthly = create(:subscription, user: user, name: "残す月額固定費", amount: 300, oshis: [ oshi ])
    yearly = create(:subscription, :yearly, user: user, name: "残す年額固定費", amount: 4800, oshis: [ second_oshi ])
    deleted = create(:subscription, user: user, name: "削除する月額固定費", amount: 700, oshis: [ oshi, second_oshi ])
    sign_in
    open_data
    check_fixed_costs(monthly: "1,000円", yearly: "4,800円")
    open_fixed_costs

    dismiss_confirm("この固定費を削除しますか？") do
      within("main section.card", text: deleted.name) { click_button "削除", exact: true }
    end
    expect(page).to have_css("main h2", text: deleted.name, exact_text: true)
    open_data
    check_fixed_costs(monthly: "1,000円", yearly: "4,800円")

    open_fixed_costs
    accept_confirm("この固定費を削除しますか？") do
      within("main section.card", text: deleted.name) { click_button "削除", exact: true }
    end
    expect(page).to have_current_path(subscriptions_path)
    expect(page).to have_css("[role='status']", text: "固定費を削除しました。")
    expect(page).not_to have_css("main h2", text: deleted.name, exact_text: true)
    check_subscription(name: monthly.name, amount: "300円", cycle: "月額", oshi_name: oshi.name)
    check_subscription(name: yearly.name, amount: "4,800円", cycle: "年額", oshi_name: second_oshi.name)
    open_data
    check_fixed_costs(monthly: "300円", yearly: "4,800円")
  end
end
