require "rails_helper"
require "json"
require "base64"

RSpec.describe "Fixed costs and visualization in the browser", type: :system do
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "固定費の推しA") }
  let(:second_oshi) { create(:oshi, :approved, name: "固定費の推しB") }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second_oshi)
  end

  def sign_in(account = user)
    visit new_user_session_path
    within("main form") do
      fill_in "user_email", with: account.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
    end
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def open_subscription_choices
    unless page.has_css?("#subscription_oshi_ids details[open]", wait: 0)
      find("#subscription_oshi_ids summary").click
    end
    expect(page).to have_css("#subscription_oshi_ids details[open]")
  end

  def choose_subscription_oshi(record, checked: true)
    open_subscription_choices
    if checked
      check record.name, allow_label_click: true
    else
      uncheck record.name, allow_label_click: true
    end
  end

  def expect_subscription_choices(*records)
    open_subscription_choices
    expect(page.all("#subscription_oshi_ids input[type='checkbox']:checked", visible: :all).map(&:value)).to match_array(records.map { |record| record.id.to_s })
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
      choose_subscription_oshi(oshi)
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
      expect_subscription_choices(oshi)
      fill_in "契約名（必須）", with: "更新した年会費"
      fill_in "金額（円・必須）", with: "2400"
      select "年額", from: "請求周期（必須）"
      choose_subscription_oshi(oshi, checked: false)
      choose_subscription_oshi(second_oshi)
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
      expect_subscription_choices(second_oshi)
      choose_subscription_oshi(second_oshi, checked: false)
      click_button "更新する"
    end
    expect(page).to have_css("[role='status']", text: "固定費を更新しました。")
    check_subscription(name: "更新した年会費", amount: "2,400円", cycle: "年額", oshi_name: "指定なし")
    edit_subscription("更新した年会費")
    expect_subscription_choices
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
    expect_subscription_choices(oshi)
    expect(page).to have_css("#subscription-oshi-status:not([hidden])", text: "1人を選択中", exact_text: true)
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
  context "with monthly and yearly amount guidance" do
    def expect_guidance
      expect(page).to have_css("#subscription-amount-help", text: I18n.t("ui.subscription.amount_help"), exact_text: true, count: 1)
      expect(find("#subscription_amount")["aria-describedby"].split).to eq([ "subscription-amount-help" ])
      expect(page.all("[aria-describedby~='subscription-amount-help']").map { |element| element[:id] }).to eq([ "subscription_amount" ])
      expect(page).to have_field("金額（円・必須）", type: "number")
    end

    def amount_form_values
      page.evaluate_script(<<~JS)
        (() => {
          const result={};
          for(const id of ["subscription_name","subscription_amount","subscription_billing_cycle","subscription_started_on","subscription_ended_on"])result[id]=document.getElementById(id).value;
          result.oshi_ids=[...document.querySelectorAll("#subscription_oshi_ids input[type=checkbox]:checked")].map(input=>input.value);
          result.lock_version=document.querySelector("input[name='subscription[lock_version]']")?.value || null;
          return result;
        })()
      JS
    end

    def capture_guidance(width, mode, phase)
      record = page.evaluate_script(<<~JS)
        (() => {
          const input=document.getElementById("subscription_amount"), help=document.getElementById("subscription-amount-help");
          const style=getComputedStyle(help), box=help.getBoundingClientRect();
          return {viewport_width:innerWidth,client_width:document.documentElement.clientWidth,scroll_width:document.documentElement.scrollWidth,
            helper_count:document.querySelectorAll("#subscription-amount-help").length,
            text:help.textContent,describedby:input.getAttribute("aria-describedby"),
            required:input.required,min:input.min,step:input.step,aria_invalid:input.getAttribute("aria-invalid"),
            font_size:style.fontSize,line_height:style.lineHeight,color:style.color,
            help_left:box.left,help_right:box.right,active_id:document.activeElement.id};
        })()
      JS
      expect(record["scroll_width"]).to be <= record["client_width"]
      expect(record["client_width"]).to be <= record["viewport_width"]
      expect(record["help_left"]).to be >= 0
      expect(record["help_right"]).to be <= record["client_width"]
      browser = page.driver.browser
      size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      screenshot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
      directory = Rails.root.join(ENV.fetch("SUBSCRIPTION_GUIDANCE_CAPTURE_ROOT", "tmp/subscription-amount-guidance-20261030-ui"), ENV.fetch("SUBSCRIPTION_GUIDANCE_CAPTURE_LABEL", "local"))
      FileUtils.mkdir_p(directory)
      path = directory.join("#{width}-#{mode}-#{phase}.png")
      File.binwrite(path, Base64.strict_decode64(screenshot.fetch("data")))
      File.write(directory.join("#{width}-#{mode}-#{phase}.json"),
        JSON.pretty_generate(record.merge(mode: mode, phase: phase, fields: amount_form_values, screenshot: path.to_s)))
    end

    [ 375, 1280 ].each do |width|
      it "associates one static explanation and preserves keyboard input on new/edit errors at #{width}px" do
        page.current_window.resize_to(width, 900)
        sign_in
        %w[new edit].each do |mode|
          record = create(:subscription, :yearly, user: user, amount: 2400, oshis: [ oshi ]) if mode == "edit"
          original = record&.attributes
          count = Subscription.count
          visit(mode == "new" ? new_subscription_path : edit_subscription_path(record))
          expect(page).to have_css("main h1", exact_text: mode == "new" ? "固定費を登録" : "固定費を編集")
          expect_guidance
          amount = mode == "new" ? "0" : "2400"
          cycle = mode == "new" ? "月額" : "年額"
          fill_in "契約名（必須）", with: "保持する固定費#{mode}"
          fill_in "金額（円・必須）", with: amount
          select cycle, from: "請求周期（必須）"
          choose_subscription_oshi(oshi)
          fill_in "開始日（任意）", with: Date.new(2025, 1, 1)
          fill_in "終了日（任意）", with: Date.new(2027, 12, 31)
          select(mode == "new" ? "年額" : "月額", from: "請求周期（必須）")
          expect(page).to have_field("subscription_amount", with: amount)
          select cycle, from: "請求周期（必須）"
          expect_guidance
          find("#subscription_amount").send_keys(:tab)
          expect(page.evaluate_script("document.activeElement.id")).to eq("subscription_billing_cycle")
          fields = amount_form_values
          capture_guidance(width, mode, "form")
          expect(page.evaluate_script("document.activeElement.id")).to eq("subscription_billing_cycle")
          fill_in "契約名（必須）", with: ""
          page.execute_script("document.querySelector('main form').noValidate=true")
          click_button(mode == "new" ? "登録する" : "更新する", exact: true)
          expect(page).to have_css(".validation-errors[role='alert']")
          expect(page).to have_field("subscription_name", with: "")
          expect_guidance
          expect(amount_form_values.except("subscription_name")).to eq(fields.except("subscription_name"))
          expect(Subscription.count).to eq(count)
          expect(record.reload.attributes).to eq(original) if record
          capture_guidance(width, mode, "error")
        end
      end
    end
  end
  context "with disclosed checkbox choices" do
    let(:second_oshi) { create(:oshi, :approved, name: "固定費の推しB" + ("LongName" * 25)) }

    def expect_selection_count(count)
      message = count.zero? ? "指定なし（0人）" : "#{count}人を選択中"
      expect(page).to have_css("#subscription-oshi-status:not([hidden])", text: message, exact_text: true)
    end

    def capture_selection(width, phase, no_js: false)
      browser = page.driver.browser
      record = if no_js
        { viewport_width: width, JavaScript_disabled: true,
          checked_ids: page.all("#subscription_oshi_ids input[type=checkbox]:checked", visible: :all).map(&:value),
          summary_present: page.has_css?("#subscription_oshi_ids summary"),
          live_status_hidden: page.has_css?("#subscription-oshi-status[hidden]", visible: :all) }
      else
        page.evaluate_script(<<~JS)
          (() => {
            const group=document.getElementById("subscription_oshi_ids"), summary=group.querySelector("summary"), choices=group.querySelector(".choice-chips");
            return {viewport_width:innerWidth,client_width:document.documentElement.clientWidth,
              scroll_width:document.documentElement.scrollWidth,panel_open:group.querySelector("details").open,
              choices_client_width:choices.clientWidth,choices_scroll_width:choices.scrollWidth,
              longest_label_length:Math.max(0,...[...group.querySelectorAll("label span")].map(span=>span.textContent.length)),
              checked_ids:[...group.querySelectorAll("input[type=checkbox]:checked")].map(input=>input.value),
              posted_ids:new FormData(group.closest("form")).getAll("subscription[oshi_ids][]"),
              status:document.getElementById("subscription-oshi-status").textContent.trim(),
              summary_height:summary.getBoundingClientRect().height,
              label_heights:[...group.querySelectorAll("label")].map(label=>label.getBoundingClientRect().height),
              active_id:document.activeElement.id,focus_is_summary:document.activeElement===summary};
          })()
        JS
      end
      unless no_js
        expect(record["scroll_width"]).to be <= record["client_width"]
        expect(record["summary_height"]).to be >= 44
        if record["panel_open"]
          expect(record["label_heights"]).to all(be >= 44)
          expect(record["choices_scroll_width"]).to be <= record["choices_client_width"]
        end
        expect(record["posted_ids"]).to eq([ "" ] + record["checked_ids"])
      end
      size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      screenshot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
      directory = Rails.root.join("tmp/oshi-choice-ui-a-20261030-ui", ENV.fetch("OSHI_CHOICE_CAPTURE_LABEL", "local"))
      FileUtils.mkdir_p(directory)
      path = directory.join("#{width}-#{phase}.png")
      File.binwrite(path, Base64.strict_decode64(screenshot.fetch("data")))
      File.write(directory.join("#{width}-#{phase}.json"), JSON.pretty_generate(record.merge(screenshot: path.to_s)))
    end

    [ 375, 1280 ].each do |width|
      it "keeps keyboard choices, errors, unsaved cancel and explicit zero-selection save at #{width}px" do
        record = create(:subscription, user: user, name: "選択確認の固定費", amount: 0, oshis: [ oshi, second_oshi ],
          started_on: Date.new(2025, 1, 1), ended_on: Date.new(2027, 12, 31))
        registrations = UserOshi.count
        original = record.attributes
        page.current_window.resize_to(width, 900)
        sign_in
        visit edit_subscription_path(record)
        expect(page).to have_field("subscription_name", with: record.name)
        expect_selection_count(2)
        expect(page).to have_no_css("#subscription_oshi_ids details[open]")
        capture_selection(width, "initial-closed")
        summary = find("#subscription_oshi_ids summary")
        summary.send_keys(:enter)
        expect(page).to have_css("#subscription_oshi_ids details[open]")
        summary.send_keys(:tab)
        expect(page.evaluate_script("document.activeElement.type")).to eq("checkbox")
        expect(page.evaluate_script("document.activeElement.id")).to eq("subscription_oshi_ids_#{oshi.id}")
        page.driver.browser.action.send_keys(:space).perform
        expect_selection_count(1)
        expect_subscription_choices(second_oshi)
        page.execute_script("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,isComposing:true}))")
        expect(page).to have_css("#subscription_oshi_ids details[open]")
        page.driver.browser.action.send_keys(:escape).perform
        expect(page).to have_no_css("#subscription_oshi_ids details[open]")
        expect(page.evaluate_script("document.activeElement===document.querySelector('#subscription_oshi_ids summary')")).to be(true)
        expect_selection_count(1)
        find("#subscription_oshi_ids summary").send_keys(:space)
        expect(page).to have_css("#subscription_oshi_ids details[open]")
        page.execute_script(<<~JS)
          window.choiceArea=document.getElementById("subscription_oshi_ids");
          window.choiceAnchor=document.createComment("choice reconnect");
          window.choiceArea.before(window.choiceAnchor);window.choiceArea.remove();
        JS
        page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
        page.execute_script("window.choiceAnchor.replaceWith(window.choiceArea)")
        expect_selection_count(1)
        expect_subscription_choices(second_oshi)
        capture_selection(width, "open-one-selected")
        fill_in "subscription_name", with: ""
        page.execute_script("document.querySelector('main form').noValidate=true")
        click_button "更新する"
        expect(page).to have_css(".validation-errors[role=alert]")
        expect_selection_count(1)
        expect_subscription_choices(second_oshi)
        expect(page).to have_field("subscription_amount", with: "0")
        expect(page).to have_select("subscription_billing_cycle", selected: "月額")
        expect(find("#subscription_started_on").value).to eq("2025-01-01")
        expect(find("#subscription_ended_on").value).to eq("2027-12-31")
        expect(find("input[name='subscription[lock_version]']", visible: :all).value).to eq(original["lock_version"].to_s)
        expect(record.reload.attributes).to eq(original)
        capture_selection(width, "error-retained")
        fill_in "subscription_name", with: "複数選択を保存した固定費"
        choose_subscription_oshi(oshi)
        expect_selection_count(2)
        click_button "更新する"
        expect(page).to have_css("main h2", exact_text: "複数選択を保存した固定費")
        expect(record.reload.oshi_ids).to match_array([ oshi.id, second_oshi.id ])
        saved = record.attributes
        edit_subscription(record.name)
        expect_selection_count(2)
        choose_subscription_oshi(oshi, checked: false)
        fill_in "subscription_name", with: "保存しない入力"
        click_link "固定費一覧へ戻る"
        expect(page).to have_css("main h1", exact_text: "固定費一覧")
        expect(record.reload.attributes).to eq(saved)
        edit_subscription(record.name)
        expect_selection_count(2)
        expect_subscription_choices(oshi, second_oshi)
        choose_subscription_oshi(oshi, checked: false)
        choose_subscription_oshi(second_oshi, checked: false)
        expect_selection_count(0)
        capture_selection(width, "zero-selection")
        click_button "更新する"
        expect(page).to have_css("main h1", exact_text: "固定費一覧")
        expect(record.reload.oshi_ids).to be_empty
        expect(UserOshi.count).to eq(registrations)
        check_subscription(name: record.name, amount: "0円", cycle: "月額", oshi_name: "指定なし")
      end
    end

    it "keeps native disclosure and checkbox submission usable with JavaScript disabled" do
      page.current_window.resize_to(375, 900)
      sign_in
      page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
      begin
        visit new_subscription_path
        expect(page).to have_css("main h1", exact_text: "固定費を登録")
        expect(page).to have_css("#subscription-oshi-status[hidden]", visible: :all)
        open_subscription_choices
        choose_subscription_oshi(oshi)
        choose_subscription_oshi(second_oshi)
        expect_subscription_choices(oshi, second_oshi)
        capture_selection(375, "no-js", no_js: true)
        fill_in "subscription_name", with: "JSなしの固定費"
        fill_in "subscription_amount", with: "1000"
        select "月額", from: "請求周期（必須）"
        click_button "登録する", exact: true
        expect(page).to have_css("main h2", exact_text: "JSなしの固定費")
        saved = user.subscriptions.find_by!(name: "JSなしの固定費")
        expect(saved.oshi_ids).to match_array([ oshi.id, second_oshi.id ])
      ensure
        page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
      end
    end

    it "offers an explicit empty personal scope and saves unspecified without exposing another user's choices" do
      empty_user = create(:user)
      page.current_window.resize_to(1280, 900)
      sign_in(empty_user)
      visit new_subscription_path
      expect(page).to have_css("main h1", exact_text: "固定費を登録")
      expect_selection_count(0)
      open_subscription_choices
      expect(page).to have_text("登録済みの推しはありません。指定なしで保存できます。")
      expect(page).to have_no_css("#subscription_oshi_ids input[type=checkbox]", visible: :all)
      expect(page).not_to have_text(oshi.name)
      expect(page).not_to have_text(second_oshi.name)
      capture_selection(1280, "no-owned-choices")
      fill_in "subscription_name", with: "指定なしの固定費"
      fill_in "subscription_amount", with: "0"
      select "年額", from: "請求周期（必須）"
      click_button "登録する", exact: true
      expect(page).to have_css("main h2", exact_text: "指定なしの固定費")
      expect(empty_user.subscriptions.find_by!(name: "指定なしの固定費").oshi_ids).to be_empty
      expect(user.subscriptions).to be_empty
    end
  end
end
