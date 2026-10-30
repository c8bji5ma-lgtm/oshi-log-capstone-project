require "rails_helper"

RSpec.describe "Mobile activity form", type: :system do
  include_context "emotion master data"

  it "wraps many long choices without horizontal overflow" do
    user = create(:user)
    25.times do |index|
      registration = create(:user_oshi, user: user)
      registration.oshi.update!(name: "長い推し名#{index + 1}-#{'あ' * 40}")
    end
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit new_activity_path
    expect(page.all("input[type='checkbox']", visible: :all).size).to eq(32)

    [ [ 375, 812, "mobile" ], [ 1280, 900, "desktop" ] ].each do |width, height, label|
      page.current_window.resize_to(width, height)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      submit = find_button("記録する")
      page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", submit)
      expect(submit).to be_visible
      save_screenshot(Rails.root.join("tmp/issue89/#{label}.png"))
    end
  end

  let(:amount_help) { "任意です。記録しない場合は空欄、0円として記録する場合は0を入力してください。" }

  [ 375, 1280 ].each do |width|
    it "explains optional amounts and preserves blank zero and regular values at #{width}px", :amount_guidance do
      user = create(:user)
      registration = create(:user_oshi, user: user)
      page.current_window.resize_to(width, 900)
      visit new_user_session_path
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
      expect(page).to have_css("main h1", text: "ホーム", exact_text: true)

      [ [ "", nil, "0", 0 ], [ "0", 0, "1250", 1250 ], [ "1250", 1250, "", nil ] ].each_with_index do |(value, expected, edited, edited_expected), index|
        title = "金額案内#{width}-#{index}"
        visit new_activity_path
        within("main form") do
          check registration.oshi.name, allow_label_click: true
          fill_in "活動日（必須）", with: Date.new(2026, 10, 1)
          select "ライブ・イベント", from: "カテゴリ（必須）"
          fill_in "タイトル（必須）", with: title
          fill_in "場所", with: "保持する場所"
          fill_in "メモ", with: "保持するメモ"
          fill_in "金額（円）", with: value
        end
        expect_amount_guidance
        capture_amount_guidance(width, "new") if index.zero?

        if index.zero?
          native = []
          %w[-1 1.5].each do |invalid|
            fill_in "金額（円）", with: invalid
            validity = page.evaluate_script(<<~JS)
              (() => {
                const input = document.querySelector("#activity_amount");
                return { range_underflow: input.validity.rangeUnderflow, step_mismatch: input.validity.stepMismatch };
              })()
            JS
            expect(validity.fetch(invalid == "-1" ? "range_underflow" : "step_mismatch")).to be(true)
            count = user.activities.count
            click_button "記録する"
            expect(page).to have_current_path(new_activity_path)
            expect(user.activities.count).to eq(count)
            expect(page).to have_field("金額（円）", with: invalid)
            expect(page).to have_field("タイトル（必須）", with: title)
            expect(page).to have_field("場所", with: "保持する場所")
            expect(page).to have_field("メモ", with: "保持するメモ")
            native << { value: invalid, validity: validity, DB_count_before: count, DB_count_after: user.activities.count }
          end
          directory = Rails.root.join("tmp/activity-amount-guidance-ui", ENV.fetch("AMOUNT_GUIDANCE_CAPTURE_LABEL", "local"))
          File.write(directory.join("#{width}-native-invalid.json"), JSON.pretty_generate(native))
          fill_in "金額（円）", with: value
        end

        click_button "記録する"
        expect(page).to have_css("[role='status']", text: "活動記録を登録しました。")
        activity = user.activities.find_by!(title: title)
        expect(activity.amount).to eq(expected)
        visit edit_activity_path(activity)
        expect_amount_guidance
        expect(page).to have_field("金額（円）", with: value)
        expect(page).to have_field("場所", with: "保持する場所")
        expect(page).to have_field("メモ", with: "保持するメモ")
        expect(page).to have_checked_field(registration.oshi.name, visible: :all)
        capture_amount_guidance(width, "edit") if index.zero?

        fill_in "金額（円）", with: edited
        click_button "更新する"
        expect(page).to have_css("[role='status']", text: "活動記録を更新しました。")
        expect(activity.reload.amount).to eq(edited_expected)
        expect(activity).to have_attributes(title: title, place: "保持する場所", memo: "保持するメモ", occurred_on: Date.new(2026, 10, 1))
        expect(activity.oshi_ids).to eq([ registration.oshi_id ])
        visit edit_activity_path(activity)
        expect_amount_guidance
        expect(page).to have_field("金額（円）", with: edited)
      end
    end
  end

  def expect_amount_guidance
    field = find_field("金額（円）")
    expect(field["aria-describedby"].split).to include("activity-amount-help")
    expect(field["aria-invalid"]).to eq("false")
    expect(page).to have_css("#activity-amount-help", text: amount_help, exact_text: true, count: 1)
  end

  def capture_amount_guidance(width, mode)
    field = find_field("金額（円）")
    focus_before = page.evaluate_script("document.activeElement.id")
    page.execute_script("arguments[0].closest('.form-field').scrollIntoView({ block: 'center', behavior: 'instant' })", field)
    record = page.evaluate_script(<<~JS)
      (() => {
        const input = document.querySelector("#activity_amount");
        const label = input.labels[0], help = document.querySelector("#activity-amount-help");
        let background = help, backgroundColor;
        while (background) {
          backgroundColor = getComputedStyle(background).backgroundColor;
          if (backgroundColor !== "rgba(0, 0, 0, 0)" && backgroundColor !== "transparent") break;
          background = background.parentElement;
        }
        return {
          label: label.textContent, help: help.textContent,
          input_id: input.id, label_for: label.htmlFor,
          input_id_count: document.querySelectorAll("#activity_amount").length,
          help_id_count: document.querySelectorAll("#activity-amount-help").length,
          description_ids: input.getAttribute("aria-describedby").split(/\\s+/),
          invalid: input.getAttribute("aria-invalid"), required: input.required,
          min: input.min, step: input.step, value: input.value,
          label_bounds: label.getBoundingClientRect().toJSON(),
          input_bounds: input.getBoundingClientRect().toJSON(),
          help_bounds: help.getBoundingClientRect().toJSON(),
          color: getComputedStyle(help).color, background_color: backgroundColor,
          font_size: getComputedStyle(help).fontSize, line_height: getComputedStyle(help).lineHeight,
          viewport_width: innerWidth, viewport_height: innerHeight,
          scroll_width: document.documentElement.scrollWidth,
          active_id: document.activeElement.id, scroll_y: scrollY
        };
      })()
    JS
    directory = Rails.root.join("tmp/activity-amount-guidance-ui", ENV.fetch("AMOUNT_GUIDANCE_CAPTURE_LABEL", "local"))
    FileUtils.mkdir_p(directory)
    image_path = directory.join("#{width}-#{mode}.png")
    screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
    File.binwrite(image_path, Base64.strict_decode64(screenshot.fetch("data")))
    record["screenshot"] = image_path.to_s
    record["mode"] = mode
    record["focus_before_inspection_scroll"] = focus_before
    record["test_scrolled_section_into_view_for_inspection"] = true
    File.write(directory.join("#{width}-#{mode}.json"), JSON.pretty_generate(record))
    expect(record["active_id"]).to eq(focus_before)
    expect(record["label"]).to eq("金額（円）")
    expect(record["help"]).to eq(amount_help)
    expect(record["input_id"]).to eq(record["label_for"])
    expect(record["input_id_count"]).to eq(1)
    expect(record["help_id_count"]).to eq(1)
    expect(record["description_ids"]).to include("activity-amount-help")
    expect(record["required"]).to be(false)
    expect(record["min"]).to eq("0")
    expect(record["step"]).to eq("1")
    expect(record["scroll_width"]).to be <= record["viewport_width"]
    %w[label_bounds input_bounds help_bounds].each do |name|
      bounds = record.fetch(name)
      expect(bounds["top"]).to be >= 0
      expect(bounds["bottom"]).to be <= record["viewport_height"]
      expect(bounds["left"]).to be >= 0
      expect(bounds["right"]).to be <= record["viewport_width"]
    end
    expect(record["label_bounds"]["bottom"]).to be <= record["input_bounds"]["top"]
    expect(record["input_bounds"]["bottom"]).to be <= record["help_bounds"]["top"]
  end
end
