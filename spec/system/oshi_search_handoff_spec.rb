require "rails_helper"
require_relative "../support/started_period_picker"

RSpec.describe "Oshi search to registration handoff", type: :system do
  include StartedPeriodPicker
  let(:user) { create(:user) }
  let(:cleared_message) { "前の検索の登録名をクリアしました。" }

  def open_registration
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit new_oshi_path
    expect(page).to have_css("[data-controller='oshi-registration']")
    @initial_live_status_count = page.evaluate_script("document.querySelector('[data-controller=oshi-registration]').querySelectorAll('[role=status]').length")
    expect(page).to have_css("[data-oshi-registration-target='status'][role='status'][aria-atomic='true']", count: 1, visible: :all)
  end

  def search(query, pointer: false)
    fill_in "推しを検索", with: query
    if pointer
      button = find_button("検索", exact: true)
      page.driver.browser.action.move_to(button.native).click.perform
    else
      click_button "検索", exact: true
    end
  end

  def draft_form
    "form[action='#{oshis_path}']"
  end

  def intercept_searches
    page.execute_script(<<~JS, new_oshi_path)
      const path = arguments[0];
      window.__oshiOriginalFetch = window.fetch.bind(window);
      window.__oshiSearchQueue = [];
      document.documentElement.dataset.testSearchQueue = "0";
      window.fetch = (input, options = {}) => {
        const url = new URL(input instanceof Request ? input.url : input.toString(), location.href);
        // This legacy queue controls confirmed handoffs; typing candidates have their own adversarial specs.
        if (url.pathname !== path || options.headers?.Accept !== "text/html" || url.searchParams.get("suggest") === "1") {
          return window.__oshiOriginalFetch(input, options);
        }
        return new Promise((resolve, reject) => {
          // Ignore AbortSignal deliberately: the UI must also reject late responses itself.
          window.__oshiSearchQueue.push({ url: url.toString(), resolve, reject });
          document.documentElement.dataset.testSearchQueue = String(window.__oshiSearchQueue.length);
        });
      };
    JS
  end

  def queued(count)
    expect(page).to have_css("html[data-test-search-queue='#{count}']")
  end

  def settle(index, outcome = "normal")
    result = page.evaluate_async_script(<<~JS, index, outcome)
      const index = arguments[0], outcome = arguments[1], done = arguments[arguments.length - 1];
      const entry = window.__oshiSearchQueue[index];
      (async () => {
        if (outcome === "network") entry.reject(new TypeError("Network failure"));
        else if (outcome === "http") entry.resolve(new Response("Unavailable", { status: 503 }));
        else if (outcome === "invalid") {
          const response = await window.__oshiOriginalFetch(entry.url, { headers: { Accept: "text/html" } });
          const original = new DOMParser().parseFromString(await response.text(), "text/html");
          if (response.status !== 200 || response.redirected || response.url !== entry.url ||
              !response.headers.get("Content-Type")?.toLowerCase().includes("text/html") ||
              !original.querySelector("#oshi-search-results")) {
            throw new Error("Invalid HTML fixture requires a normal matching search response");
          }
          const body = "<html>No search result</html>";
          const invalid = new Response(body, {
            status: response.status, statusText: response.statusText, headers: response.headers
          });
          Object.defineProperty(invalid, "url", { value: response.url });
          window.__oshiInvalidResponse = {
            status: invalid.status, urlMatches: invalid.url === entry.url,
            html: invalid.headers.get("Content-Type").toLowerCase().includes("text/html"),
            originalResultPresent: !!original.querySelector("#oshi-search-results"),
            replacementResultPresent: !!new DOMParser().parseFromString(body, "text/html").querySelector("#oshi-search-results")
          };
          entry.resolve(invalid);
        }
        else {
          const url = new URL(entry.url);
          if (outcome === "wrong-query") url.searchParams.set("q", "別の応答");
          const response = await window.__oshiOriginalFetch(url, { headers: { Accept: "text/html" } });
          await response.clone().text();
          entry.resolve(response);
        }
        setTimeout(() => done("settled"), 0);
      })().catch(error => done(error.message));
    JS
    expect(result).to eq("settled")
  end

  [ 375, 1280 ].each do |width|
    it "clears only the old automatic name on found results and preserves both drafts at #{width}px" do
      candidate = create(:oshi, :approved, name: "登録済みの候補")
      open_registration
      page.current_window.resize_to(width, 900)
      counts = [ Oshi.count, UserOshi.count ]
      within(draft_form) do
        select "声優", from: "種別（必須）"
        fill_in "所属・作品", with: "保持する作品"
        select_started_period "2022/04"
        attach_file "登録画像", Rails.root.join("spec/fixtures/files/image.png")
        expect(page).to have_css("input[type='file'][data-image-upload-ready='true']")
      end

      search("新しい候補#{width}")
      expect(page).to have_field("推し名（必須）", with: "新しい候補#{width}")
      expect(page).to have_css("#oshi_name:focus")
      expect(find("[data-oshi-registration-target='status']").text).to eq("検索した名前を登録欄に引き継ぎました。入力内容を確認してください。")
      expect(page).to have_css("a[href='#oshi-registration'][aria-current='step']")
      within(draft_form) do
        expect(page).to have_select("種別（必須）", selected: "声優")
        expect(page).to have_field("所属・作品", with: "保持する作品")
        expect(page).to have_field("推し始め", with: "2022/04", visible: :all)
      end
      expect(page.evaluate_script("document.querySelector('#new_user_oshi_library_images').files.length")).to eq(1)
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)

      find("a", text: "既存の推しを検索し直す").send_keys(:enter)
      expect(page).to have_css("input[name='q']:focus")
      expect(page).to have_field("推しを検索", with: "新しい候補#{width}")
      intercept_searches
      fill_in "推しを検索", with: candidate.name
      find("input[name='q']").send_keys(:enter)
      queued(1)
      expect(find("[data-oshi-registration-target='status']").text).to eq("候補を検索しています。")
      position = settled_navigation_state
      settle(0)
      capture_cleared_name(width, position, "first")
      expect(page).to have_field(candidate.name, type: "radio", exact: false)
      expect(page).to have_field("推し名（必須）", with: "")
      expect(find("[data-oshi-registration-target='status']").text).to eq(cleared_message)
      expect(navigation_state).to eq(position)
      within("form[action='#{user_oshis_path}']") do
        choose candidate.name, exact: false
        select_started_period "2020"
        attach_file "登録画像", Rails.root.join("spec/fixtures/files/image.png")
        expect(page).to have_css("input[type='file'][data-image-upload-ready='true']")
      end

      search("別の新しい候補#{width}")
      queued(2)
      settle(1)
      expect(page).to have_field("推し名（必須）", with: "別の新しい候補#{width}")
      expect(page).to have_field("new_user_oshi_started_period", with: "2022/04", visible: :all)
      click_link "既存の推しを検索し直す"
      search(candidate.name)
      queued(3)
      position = settled_navigation_state
      settle(2)
      capture_cleared_name(width, position, "second")
      expect(page).to have_css("#oshi-search-results[data-oshi-search-state='results']")
      expect(page).to have_field("existing_user_oshi_started_period", with: "2020", visible: :all)
      expect(page.evaluate_script("document.querySelector('#existing_user_oshi_library_images').files.length")).to eq(1)
      expect(page).to have_field("推し名（必須）", with: "")
      expect(find("[data-oshi-registration-target='status']").text).to eq(cleared_message)
      within(draft_form) do
        expect(page).to have_select("種別（必須）", selected: "声優")
        expect(page).to have_field("所属・作品", with: "保持する作品")
        expect(page).to have_field("new_user_oshi_started_period", with: "2022/04", visible: :all)
      end
      expect(page.evaluate_script("document.querySelector('#new_user_oshi_library_images').files.length")).to eq(1)
      expect(navigation_state).to eq(position)
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
    end
  end

  it "keeps a manually entered or deliberately cleared registration name" do
    candidate = create(:oshi, :approved, name: "手入力を保護する候補")
    open_registration
    fill_in "推し名（必須）", with: "本人が決めた登録名"
    search("見つからない検索名")
    expect(page).to have_text("入力済みの登録名は変更していません。")
    expect(page).to have_field("推し名（必須）", with: "本人が決めた登録名")
    search(candidate.name)
    expect(page).to have_field(candidate.name, type: "radio", exact: false)
    expect(page).to have_field("推し名（必須）", with: "本人が決めた登録名")
    expect(find("[data-oshi-registration-target='status']", visible: :all).text(:all)).to eq("")
    fill_in "推し名（必須）", with: ""
    search("別の未登録名")
    expect(page).to have_text("入力済みの登録名は変更していません。")
    expect(page).to have_field("推し名（必須）", with: "")
    search(candidate.name)
    expect(page).to have_field(candidate.name, type: "radio", exact: false)
    expect(page).to have_field("推し名（必須）", with: "")
    expect(find("[data-oshi-registration-target='status']", visible: :all).text(:all)).to eq("")
  end

  it "keeps a name that was edited and then changed back to its automatic text" do
    candidate = create(:oshi, :approved, name: "同値編集後の候補")
    open_registration
    search("自動補完された名前")
    expect(page).to have_field("推し名（必須）", with: "自動補完された名前")
    fill_in "推し名（必須）", with: "一度編集した名前"
    fill_in "推し名（必須）", with: "自動補完された名前"
    search(candidate.name)
    expect(page).to have_field(candidate.name, type: "radio", exact: false)
    expect(page).to have_field("推し名（必須）", with: "自動補完された名前")
    expect(find("[data-oshi-registration-target='status']", visible: :all).text(:all)).to eq("")
  end

  it "keeps a prefilled name whose origin is unknown after a real Stimulus reconnect" do
    candidate = create(:oshi, :approved, name: "再接続後の候補")
    open_registration
    search("再接続前の補完名")
    expect(page).to have_field("推し名（必須）", with: "再接続前の補完名")
    expect(page.evaluate_async_script(<<~JS)).to eq("reconnected")
      const done = arguments[arguments.length - 1];
      const root = document.querySelector("[data-controller='oshi-registration']");
      const parent = root.parentNode, sibling = root.nextSibling;
      root.remove();
      setTimeout(() => {
        parent.insertBefore(root, sibling);
        setTimeout(() => done("reconnected"), 0);
      }, 0);
    JS
    search(candidate.name)
    expect(page).to have_field(candidate.name, type: "radio", exact: false)
    expect(page).to have_field("推し名（必須）", with: "再接続前の補完名")
    expect(find("[data-oshi-registration-target='status']", visible: :all).text(:all)).to eq("")
  end

  it "defers input candidates during IME and accepts a subsequent explicit Enter for the handoff" do
    open_registration
    search("IME前の補完名")
    expect(page).to have_field("推し名（必須）", with: "IME前の補完名")
    click_link "既存の推しを検索し直す"
    intercept_searches
    fill_in "推しを検索", with: "変換している名前"
    page.execute_script(<<~JS)
      const input = document.querySelector("input[name='q']");
      input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", keyCode: 229, isComposing: true, bubbles: true }));
      input.form.requestSubmit();
      input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", keyCode: 13, bubbles: true }));
      document.querySelector("[data-oshi-registration-target='searchButton']").click();
      input.form.requestSubmit();
      input.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", bubbles: true }));
    JS
    queued(0)
    expect(page).to have_field("推し名（必須）", with: "IME前の補完名")
    find("input[name='q']").send_keys(:enter)
    queued(1)
    settle(0)
    expect(page).to have_field("推し名（必須）", with: "変換している名前")
    expect(page).to have_css("#oshi_name:focus")
  end

  it "ignores duplicate, reversed and edited-away search responses" do
    candidate = create(:oshi, :approved, name: "見つかる推し")
    open_registration
    intercept_searches
    search("古い0件")
    queued(1)
    click_button "検索", exact: true
    queued(1)
    search(candidate.name)
    queued(2)
    settle(1)
    expect(page).to have_field(candidate.name, type: "radio", exact: false)
    expect(find("[data-oshi-registration-target='status']", visible: :all).text(:all)).to eq("")
    settle(0)
    expect(page).to have_field("推し名（必須）", with: "")
    expect(page).to have_css("a[href='#oshi-existing'][aria-current='step']")
    search(candidate.name)
    queued(3)
    search("最新の0件")
    queued(4)
    settle(3)
    expect(page).to have_field("推し名（必須）", with: "最新の0件")
    settle(2)
    expect(page).to have_field("推し名（必須）", with: "最新の0件")
    expect(page).not_to have_field(candidate.name, type: "radio", exact: false)
    search("変更される0件", pointer: true)
    queued(5)
    fill_in "推しを検索", with: "まだ確定していない入力"
    settle(4)
    expect(page).to have_field("推し名（必須）", with: "最新の0件")
    expect(page).to have_field("推しを検索", with: "まだ確定していない入力")
  end

  it "does not turn blank input, transport failure or invalid responses into an empty result" do
    open_registration
    search("失敗前の補完名")
    expect(page).to have_field("推し名（必須）", with: "失敗前の補完名")
    click_link "既存の推しを検索し直す"
    intercept_searches
    [ "", "  ", "　" ].each { |query| search(query) }
    queued(0)
    expect(page).to have_field("推し名（必須）", with: "失敗前の補完名")
    %w[network http invalid wrong-query].each_with_index do |outcome, index|
      search("失敗する検索#{index}")
      queued(index + 1)
      settle(index, outcome)
      if outcome == "invalid"
        expect(page.evaluate_script("window.__oshiInvalidResponse")).to include(
          "status" => 200, "urlMatches" => true, "html" => true,
          "originalResultPresent" => true, "replacementResultPresent" => false
        )
      end
      expect(page).to have_text("検索できませんでした。入力内容は残しています。")
      expect(page).to have_field("推し名（必須）", with: "失敗前の補完名")
      expect(page).to have_css("a[href='#oshi-existing'][aria-current='step']")
    end
  end

  it "cancels a handoff when another field is edited or the page is left" do
    candidate = create(:oshi, :approved, name: "離脱後に届く候補")
    open_registration
    search("離脱前の補完名")
    expect(page).to have_field("推し名（必須）", with: "離脱前の補完名")
    click_link "既存の推しを検索し直す"
    intercept_searches
    search("後から届く0件")
    queued(1)
    fill_in "所属・作品", with: "入力を続ける作品"
    active_id = page.evaluate_script("document.activeElement.id")
    scroll_y = page.evaluate_script("window.scrollY")
    settle(0)
    expect(page).to have_field("所属・作品", with: "入力を続ける作品")
    expect(page).to have_field("推し名（必須）", with: "離脱前の補完名")
    expect(page.evaluate_script("document.activeElement.id")).to eq(active_id)
    expect(page.evaluate_script("window.scrollY")).to eq(scroll_y)

    page.execute_script("window.__oshiNameBeforeLeave = document.querySelector('#oshi_name')")
    search(candidate.name)
    queued(2)
    click_link "推し一覧へ戻る"
    expect(page).to have_current_path(oshis_path)
    settle(1)
    expect(page).to have_current_path(oshis_path)
    expect(page).to have_css("main h1", text: "推し一覧", exact_text: true)
    expect(page.evaluate_script("window.__oshiNameBeforeLeave.value")).to eq("離脱前の補完名")
  end

  def navigation_state
    page.evaluate_script("({ active_id: document.activeElement.id, scroll_y: window.scrollY })")
  end

  def settled_navigation_state
    record = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1], started = performance.now();
      const samples = [];
      let previous, stable = 0;
      function sample() {
        const state = { active_id: document.activeElement.id, scroll_y: window.scrollY };
        samples.push(state.scroll_y);
        stable = state.scroll_y === previous ? stable + 1 : 0;
        previous = state.scroll_y;
        if (stable >= 3) return done({ state, samples, elapsed_ms: performance.now() - started });
        if (performance.now() - started > 2000) return done({ error: "prior navigation did not settle", samples });
        requestAnimationFrame(sample);
      }
      requestAnimationFrame(sample);
    JS
    expect(record).not_to have_key("error")
    (@navigation_settles ||= []) << record
    record.fetch("state")
  end

  def capture_cleared_name(width, before, phase)
    browser = page.driver.browser
    size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    full = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
    viewport = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
    directory = Rails.root.join("tmp/ux01-notice-placement-ui", ENV.fetch("UX01_NOTICE_CAPTURE_LABEL", "initial"))
    FileUtils.mkdir_p(directory)
    image_path = directory.join("#{width}-#{phase}-cleared.png")
    viewport_path = directory.join("#{width}-#{phase}-cleared-viewport.png")
    File.binwrite(image_path, Base64.strict_decode64(full.fetch("data")))
    File.binwrite(viewport_path, Base64.strict_decode64(viewport.fetch("data")))
    record = page.evaluate_script(<<~JS)
      (() => {
        const status = document.querySelector("[data-oshi-registration-target='status']");
        const rect = status.getBoundingClientRect();
        const root = document.querySelector("[data-controller='oshi-registration']");
        return {
          name: document.querySelector("#oshi_name").value,
          query: document.querySelector("input[name='q']").value,
          status: status.textContent,
          status_top: rect.top, status_bottom: rect.bottom,
          status_left: rect.left, status_right: rect.right,
          status_height: rect.height, status_position: getComputedStyle(status).position,
          handoff_status_count: root.querySelectorAll("[data-oshi-registration-target='status']").length,
          live_status_count: root.querySelectorAll("[role='status']").length,
          live_notice_text_occurrences: Array.from(root.querySelectorAll("[role='status'], [aria-live]")).filter(node => node.textContent === status.textContent).length,
          notice_text_occurrences: Array.from(root.querySelectorAll("p")).filter(node => node.textContent === status.textContent).length,
          inner_height: innerHeight,
          type: document.querySelector("#oshi_oshi_type").value,
          affiliation: document.querySelector("#oshi_affiliation").value,
          new_period: document.querySelector("#new_user_oshi_started_period").value,
          existing_period: document.querySelector("#existing_user_oshi_started_period").value,
          new_files: document.querySelector("#new_user_oshi_library_images").files.length,
          existing_files: document.querySelector("#existing_user_oshi_library_images").files.length,
          viewport_width: innerWidth,
          scroll_width: document.documentElement.scrollWidth
        };
      })()
    JS
    record["phase"] = phase
    record["initial_live_status_count"] = @initial_live_status_count
    record["prior_navigation_settles"] = @navigation_settles
    record["navigation_before"] = before
    record["navigation_after"] = navigation_state
    record["screenshot"] = image_path.to_s
    record["viewport_screenshot"] = viewport_path.to_s
    File.write(directory.join("#{width}-#{phase}-cleared.json"), JSON.pretty_generate(record))
    expect(record["navigation_after"]).to eq(before)
    expect(record["status"]).to eq(cleared_message)
    expect(record["status_top"]).to be >= 0
    expect(record["status_bottom"]).to be <= record["inner_height"]
    expect(record["status_left"]).to be >= 0
    expect(record["status_right"]).to be <= record["viewport_width"]
    expect(record["status_height"]).to be > 0
    expect(record["status_position"]).not_to be_in(%w[fixed sticky])
    expect(record["handoff_status_count"]).to eq(1)
    expect(record["live_status_count"]).to eq(record["initial_live_status_count"])
    expect(record["live_notice_text_occurrences"]).to eq(1)
    expect(record["notice_text_occurrences"]).to eq(1)
  end
end
