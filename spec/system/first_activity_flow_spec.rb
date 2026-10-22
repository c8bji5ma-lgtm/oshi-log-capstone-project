require "rails_helper"

RSpec.describe "First activity onboarding", type: :system do
  let(:user) { create(:user) }

  it "guides an empty account through a pending oshi to its first activity" do
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "Log in"

    click_link "最初の推しを登録", exact: true
    expect(page).to have_current_path(new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION))
    within("section", text: "既存の推しから選ぶ") do
      fill_in "推しを検索", with: "見つからない候補"
      click_button "検索"
    end
    expect(page).to have_text("該当する推しが見つかりませんでした。")
    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    expect(query).to include("q" => "見つからない候補",
      "continue" => ApplicationController::FIRST_ACTIVITY_CONTINUATION)
    expect(page).to have_field("continue", type: :hidden,
      with: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
    page.go_back
    expect(page).to have_current_path(new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION))

    within("section", text: "新しい推しを登録") do
      fill_in "推し名（必須）", with: "初回導線の推し"
      select "アイドル", from: "種別（必須）"
      fill_in "所属・作品", with: "初回作品"
      click_button "新しい推しを登録"
    end

    expect(page).to have_css("main h1", text: "活動記録を登録", exact_text: true)
    created = user.user_oshis.last!
    expect(created.oshi).to be_pending
    expect(page).to have_current_path(new_activity_path(initial_oshi_id: created.oshi_id))
    expect(page).to have_checked_field("初回導線の推し", visible: :all)
    expect(page).to have_field("活動日（必須）", with: Date.current.iso8601)

    select "ライブ・イベント", from: "カテゴリ（必須）"
    fill_in "タイトル（必須）", with: "最初の記録"
    click_button "記録する"

    expect(page).to have_css("[role='status']", text: "活動記録を登録しました。")
    expect(page).to have_link("最初の記録")
    expect(user.activities.last.oshi_ids).to eq([ created.oshi_id ])
  end
end
