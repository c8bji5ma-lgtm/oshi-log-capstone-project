require "rails_helper"

RSpec.describe "Oshi registration and moderation in the browser", type: :system do
  let(:user) { create(:user) }
  let(:admin) { create(:user, :admin) }

  def sign_in_as(account)
    visit new_user_session_path
    within("main form") do
      fill_in "user_email", with: account.email
      fill_in "user_password", with: "password123"
      click_button "Log in"
    end
    expect(page).to have_current_path(root_path)
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def sign_out
    click_button "ログアウト"
    expect(page).to have_current_path(new_user_session_path)
    expect(page).to have_button("Log in")
  end

  def open_registration
    within("nav[aria-label='グローバルナビゲーション']") do
      click_link "推し一覧"
    end
    expect(page).to have_current_path(oshis_path)
    expect(page).to have_css("html:not([aria-busy]) main h1", text: "推し一覧", exact_text: true)
    click_link "推しを登録", exact: true
    expect(page).to have_css("main h1", text: "推し登録", exact_text: true)
  end

  def search_oshi(query)
    fill_in "推しを検索", with: query
    click_button "検索", exact: true
  end

  def add_candidate(name, started_period:)
    within("form[action='#{user_oshis_path}']") do
      select name, from: "既存候補"
      fill_in "推し始め", with: started_period
      click_button "選んだ推しを追加"
    end
    expect(page).to have_current_path(oshis_path)
    expect(page).to have_css("[role='status']", text: "推しを登録しました。")
    expect(page).to have_css("main h2", text: name, exact_text: true)
  end

  def open_moderation
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    click_link "推し承認管理"
    expect(page).to have_css("main h1", text: "推し承認管理", exact_text: true)
  end

  it "adds an approved search result and updates personal periods through the edit form" do
    oshi = create(:oshi, :approved, name: "検索から追加する推し")
    sign_in_as(user)
    open_registration
    search_oshi(oshi.name)
    add_candidate(oshi.name, started_period: "2023/05")

    within("main section.card", text: oshi.name) do
      expect(page).to have_text("推し始め：2023/05")
      click_link "編集", exact: true
    end
    expect(page).to have_css("main h1", text: "推し編集", exact_text: true)
    within("main form[action='#{user_oshi_path(user.user_oshis.find_by!(oshi: oshi))}']") do
      expect(page).to have_field("推し始め", with: "2023/05")
      fill_in "推し始め", with: "2021/02"
      fill_in "推し終了時期", with: "2025/07"
      click_button "推し情報を更新"
    end
    expect(page).to have_current_path(oshis_path)
    expect(page).to have_css("[role='status']", text: "推し情報を更新しました。")

    within("main section.card", text: oshi.name) do
      expect(page).to have_text("推し始め：2021/02")
      click_link "詳細", exact: true
    end
    within("main") do
      expect(page).to have_css("h1", text: "推し詳細", exact_text: true)
      expect(page).to have_css("dd", text: "2021/02", exact_text: true)
      expect(page).to have_css("dd", text: "2025/07", exact_text: true)
    end
  end

  it "registers a pending oshi, approves the application and lets another user search and add it" do
    other_user = create(:user)
    name = "ブラウザから申請する推し"
    sign_in_as(user)
    open_registration
    within("form[action='#{oshis_path}']") do
      fill_in "推し名（必須）", with: name
      select "声優", from: "種別（必須）"
      fill_in "所属・作品", with: "ブラウザ検証作品"
      fill_in "推し始め", with: "2024/04"
      click_button "新しい推しを登録", exact: true
    end
    expect(page).to have_current_path(oshis_path)
    expect(page).to have_css("main h2", text: name, exact_text: true)
    oshi = Oshi.find_by!(name: name, created_by_user: user)
    expect(oshi).to be_pending

    sign_out
    sign_in_as(admin)
    open_moderation
    within("main section.card", text: name) do
      expect(page).to have_text("種別：声優")
      expect(page).to have_text("所属：ブラウザ検証作品")
      click_button "承認", exact: true
    end
    expect(page).to have_css("[role='status']", text: "推しを承認しました。")
    expect(page).not_to have_css("main h2", text: name, exact_text: true)
    expect(oshi.reload).to be_approved

    sign_out
    sign_in_as(other_user)
    open_registration
    search_oshi(name)
    add_candidate(name, started_period: "2026")
    expect(user.user_oshis.find_by!(oshi: oshi).started_period).to eq("2024/04")
    expect(other_user.user_oshis.find_by!(oshi: oshi).started_period).to eq("2026")
  end

  it "removes a rejected application from the applicant's search candidates" do
    rejected = create(:oshi, :pending, name: "検索除外の申請", created_by_user: user)
    approved = create(:oshi, :approved, name: "検索除外の承認済み推し")
    sign_in_as(admin)
    open_moderation
    within("main section.card", text: rejected.name) { click_button "却下", exact: true }
    expect(page).to have_css("[role='status']", text: "推しを却下しました。")
    expect(rejected.reload).to be_rejected

    sign_out
    sign_in_as(user)
    open_registration
    search_oshi("検索除外")
    expect(page).to have_select("既存候補", with_options: [ approved.name ])
    expect(page).not_to have_select("既存候補", with_options: [ rejected.name ])
  end
end
