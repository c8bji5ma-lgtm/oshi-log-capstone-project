require "rails_helper"

RSpec.describe "Activity emotion selection", type: :system do
  include_context "emotion master data"

  it "registers, edits and clears multiple tags through the activity form" do
    user = create(:user)
    registration = create(:user_oshi, user: user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "Log in"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)

    visit new_activity_path
    oshi_checkbox = find("#activity_oshi_ids_#{registration.oshi_id}", visible: :all)
    40.times do
      break if page.evaluate_script("document.activeElement.id") == oshi_checkbox[:id]
      page.find("body").send_keys(:tab)
    end
    expect(page.evaluate_script("document.activeElement.id")).to eq(oshi_checkbox[:id])
    outline = page.evaluate_script("getComputedStyle(document.querySelector('##{oshi_checkbox[:id]} + span')).outlineStyle")
    expect(outline).not_to eq("none")
    oshi_checkbox.send_keys(:space)
    expect(oshi_checkbox).to be_checked
    expect(oshi_checkbox.find(:xpath, "following-sibling::span").text).to eq(registration.oshi.name)
    oshi_checkbox.send_keys(:space)
    expect(oshi_checkbox).not_to be_checked
    check registration.oshi.name, allow_label_click: true
    fill_in "活動日（必須）", with: Date.current
    select "ライブ・イベント", from: "カテゴリ（必須）"
    fill_in "タイトル（必須）", with: "感情タグの記録"
    check "嬉しい", allow_label_click: true
    check "感動", allow_label_click: true
    click_button "記録する"
    expect(page).to have_css(".activity-list .activity-emotions", text: "嬉しい、感動", exact_text: true)
    click_link "感情タグの記録"
    expect(page).to have_css("dd.activity-emotions", text: "嬉しい、感動", exact_text: true)
    click_link "編集", exact: true
    expect(page).to have_checked_field("嬉しい", visible: :all)
    expect(page).to have_checked_field("感動", visible: :all)
    uncheck "嬉しい", allow_label_click: true
    check "幸せ", allow_label_click: true
    click_button "更新する"
    expect(page).to have_css("dd.activity-emotions", text: "感動、幸せ", exact_text: true)

    click_link "編集", exact: true
    uncheck "感動", allow_label_click: true
    uncheck "幸せ", allow_label_click: true
    click_button "更新する"
    expect(page).to have_css("dd.activity-emotions", text: "—", exact_text: true)
    expect(user.activities.sole.emotions).to be_empty
  end
end
