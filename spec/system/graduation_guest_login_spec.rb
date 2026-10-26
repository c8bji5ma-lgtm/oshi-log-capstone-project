require "rails_helper"

RSpec.describe "卒業課題のゲスト体験", type: :system do
  let!(:viewer) { create(:user, email: "demo@example.com") }
  let!(:administrator) { create(:user, :admin, email: "admin@example.com") }

  before do
    %w[multi light empty].each do |name|
      create(:user, email: "#{name}@example.com")
    end
  end

  around do |example|
    previous = ENV["OSHI_GUEST_SANDBOX"]
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    example.run
  ensure
    previous.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous
  end

  it "opens viewer pages and denies administrator access through the browser" do
    visit root_path
    click_button "一般ユーザーとしてゲストログイン"
    expect(page).to have_css("main h1", text: "ホーム")
    visit my_page_path
    expect(page).to have_css("main h1", text: "マイページ")

    visit admin_oshis_path
    expect(page).to have_css("h1", text: "アクセスできません")
    click_button "ログアウト"
    expect(page).to have_current_path(new_user_session_path)
  end

  it "shows an administrator page but denies a state-changing action" do
    record = create(:oshi, :pending, name: "権限確認用", created_by_user: viewer)
    visit root_path
    click_button "管理者としてゲストログイン"
    expect(page).to have_css("main h1", text: "ホーム")

    visit admin_oshis_path
    expect(page).to have_css("main h1", text: "推し承認管理")
    within("main section.card", text: record.name) { click_button "承認" }
    expect(page).to have_content("ゲストは閲覧専用です")
    expect(record.reload).to be_pending

    visit root_path
    click_button "ログアウト"
    expect(page).to have_current_path(new_user_session_path)
  end
end
