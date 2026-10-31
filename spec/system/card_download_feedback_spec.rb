require "rails_helper"
require "tmpdir"
require_relative "../support/image_attachments"

RSpec.describe "Card download feedback", type: :system do
  include ImageAttachments

  let(:user) { create(:user) }
  let(:user_oshi) { create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "保存確認の推し")) }
  let(:network_message) { "画像を保存できませんでした。通信状況を確認し、もう一度「PNGをダウンロード」を押してください。" }

  around do |example|
    previous_services = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    previous_forgery = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    Dir.mktmpdir("ux03-card-", Rails.root.join("tmp")) do |directory|
      @download_directory = Pathname.new(directory).join("downloads")
      FileUtils.mkdir_p(@download_directory)
      storage = ActiveStorage::Service::DiskService.new(root: File.join(directory, "storage"))
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      Capybara.reset_sessions!
      @download_driver&.quit
    end
  ensure
    ActiveStorage::Blob.services = previous_services
    ActiveStorage::Blob.service = previous_service
    ApplicationController.allow_forgery_protection = previous_forgery
  end

  before do
    create(:profile, user: user, introduction: "保存する前に確認した自己紹介")
    user_oshi.representative_image.attach(image_upload)
    @download_driver = page.driver
    @download_driver.browser.download_path = @download_directory.to_s
  end

  def open_card(width = 1280)
    @width = width
    page.current_window.resize_to(width, 900)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit new_card_path
    expect(page).to have_select("主写真：#{user_oshi.oshi.name}", selected: "#{user_oshi.oshi.name}の代表画像")
    expect(page).to have_button("プレビューを作成", disabled: false)
  end

  def generate_preview
    click_button "プレビューを作成"
    expect(page).to have_css("[data-photo-card-target='status']", exact_text: "完成プレビューを確認してから保存してください。", wait: 10)
    expect(page).to have_css("[data-photo-card-target='image'][src^='blob:']") { |image| image.evaluate_script("this.complete && this.naturalWidth > 0") }
    expect(page).to have_button("PNGをダウンロード", disabled: false)
  end

  def preview_bytes
    encoded = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      fetch(document.querySelector('[data-photo-card-target="image"]').src)
        .then(response => response.blob()).then(blob => {
          const reader = new FileReader();
          reader.onload = () => done(reader.result.split(",")[1]);
          reader.readAsDataURL(blob);
        });
    JS
    Base64.strict_decode64(encoded)
  end

  def intercept_download(mode, status: nil, message: nil)
    page.execute_script(<<~JS, download_card_path, mode, status, message)
      const path = arguments[0], mode = arguments[1], status = arguments[2], message = arguments[3];
      const originalFetch = window.fetch.bind(window);
      window.__downloadRequestCount = 0;
      window.__downloadHeld = false;
      window.__downloadFinished = false;
      const editor = document.querySelector('[data-controller="photo-card"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(editor, "photo-card");
      const originalDownload = controller.download.bind(controller);
      controller.download = (...args) => {
        const promise = originalDownload(...args);
        if (!window.__firstDownloadPromise) {
          window.__firstDownloadPromise = promise;
          promise.then(() => { window.__downloadFinished = true; }, error => {
            window.__downloadUnexpected = String(error);
            window.__downloadFinished = true;
          });
        }
        return promise;
      };
      window.fetch = (input, options = {}) => {
        const url = new URL(input instanceof Request ? input.url : input.toString(), location.href);
        if (url.pathname !== path) return originalFetch(input, options);
        window.__downloadRequestCount += 1;
        if (window.__downloadRequestCount > 1) return originalFetch(input, options);
        window.__downloadSignal = options.signal;
        if (mode === "network") return Promise.reject(new TypeError("Failed to fetch"));
        if (mode === "http") {
          return Promise.resolve(new Response(JSON.stringify({error: message}), {
            status, headers: {"Content-Type":"application/json"}
          }));
        }
        if (mode === "hold-error") {
          // Ignore AbortSignal deliberately to exercise the existing stale-result guard.
          return new Promise((_resolve, reject) => {
            window.__releaseDownload = () => reject(new TypeError("Failed to fetch"));
            window.__downloadHeld = true;
          });
        }
        return originalFetch(input, options).then(async response => {
          const blob = await response.blob();
          // Preserve the real receipt/digest-verified response, but deliver it late.
          return new Promise(resolve => {
            window.__releaseDownload = () => resolve(new Response(blob, {
              status: response.status, headers: response.headers
            }));
            window.__downloadHeld = true;
          });
        });
      };
    JS
  end

  def wait_for_flag(expression)
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet, expression unless page.evaluate_script(expression)
    end
  end

  def release_download
    page.execute_script("window.__releaseDownload()")
    wait_for_flag("window.__downloadFinished === true")
    expect(page.evaluate_script("window.__downloadUnexpected || null")).to be_nil
  end

  def expect_no_progress
    expect(page).to have_css("[data-photo-card-target='status']", exact_text: "", visible: :all)
  end

  def expect_same_preview(url)
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    expect(page).to have_css("[data-photo-card-target='preview']")
    expect(page).to have_button("PNGをダウンロード", disabled: false)
  end

  def expect_invalidated
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    expect(page).to have_css("[data-photo-card-target='image']:not([src])", visible: :all)
    expect(page).to have_button("PNGをダウンロード", disabled: true, visible: :all)
    expect(@download_directory.children).to be_empty
  end

  def await_png(expected)
    expect(page).to have_css("[data-photo-card-target='status']", exact_text: "ダウンロードを開始しました。保存先をブラウザーで確認してください。", wait: 10)
    expect(page).to have_button("PNGをダウンロード", disabled: false)
    png = @download_directory.join("oshilog-card.png")
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet, "PNG download incomplete" unless png.file? && @download_directory.glob("*.crdownload").empty?
    end
    expect(File.binread(png)).to eq(expected)
    image = Vips::Image.new_from_file(png.to_s)
    expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
    png
  end

  def capture(name, preserved_png: nil)
    dir = Rails.root.join("tmp/ux03-ui/notice-confirmed")
    FileUtils.mkdir_p(dir)
    browser = page.driver.browser
    viewport = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
    File.binwrite(dir.join("#{@width}-#{name}-viewport.png"), Base64.strict_decode64(viewport.fetch("data")))
    size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: [ size.fetch("width"), page.evaluate_script("innerWidth") ].max, height: size.fetch("height"), scale: 1 })
    image_path = dir.join("#{@width}-#{name}.png")
    File.binwrite(image_path, Base64.strict_decode64(shot.fetch("data")))
    if preserved_png
      preserved_path = dir.join("#{@width}-confirmed-card.png")
      FileUtils.cp(preserved_png, preserved_path)
    end
    record = {
      path: URI.parse(page.current_url).request_uri,
      status: find("[data-photo-card-target='status']", visible: :all).text(:all),
      error: find("[data-photo-card-target='error']", visible: :all).text(:all),
      preview_url: find("[data-photo-card-target='image']")["src"],
      download_disabled: find_button("PNGをダウンロード").disabled?,
      introduction_checked: find("input[name='show_introduction']").checked?,
      request_count: page.evaluate_script("window.__downloadRequestCount"),
      viewport_width: page.evaluate_script("innerWidth"), scroll_width: page.evaluate_script("document.documentElement.scrollWidth"),
      screenshot: image_path.to_s,
      viewport_screenshot: dir.join("#{@width}-#{name}-viewport.png").to_s,
      notice_in_viewport: page.evaluate_script("(() => { const r=document.querySelector('[data-photo-card-target=error]').getBoundingClientRect(); return r.height > 0 && r.bottom > 0 && r.top < innerHeight; })()"),
      preserved_png: preserved_path&.to_s,
      png_sha256: preserved_path && Digest::SHA256.file(preserved_path).hexdigest
    }
    File.write(dir.join("#{@width}-#{name}.json"), JSON.pretty_generate(record))
  end

  [ 375, 1280 ].each do |width|
    it "explains a network failure and retries the identical preview at #{width}px" do
      open_card(width)
      uncheck "保存済みの自己紹介を表示する"
      generate_preview
      url = find("[data-photo-card-target='image']")["src"]
      png = preview_bytes
      intercept_download("network")
      click_button "PNGをダウンロード"
      expect(page).to have_css("[data-photo-card-target='error']", exact_text: network_message)
      notice_rect = find("[data-photo-card-target='error']").evaluate_script("(() => { const r=this.getBoundingClientRect(); return {top:r.top,bottom:r.bottom,viewport:innerHeight}; })()")
      puts "UX03_NOTICE_RECT #{@width} #{notice_rect.to_json}"
      # Native scrolling rounds its offset to pixels; allow only that rounding at the edges.
      expect(notice_rect.fetch("top")).to be >= -1
      expect(notice_rect.fetch("bottom")).to be <= notice_rect.fetch("viewport") + 1
      expect_no_progress
      expect_same_preview(url)
      expect(page).to have_unchecked_field("保存済みの自己紹介を表示する")
      expect(page).to have_checked_field(user_oshi.oshi.name, exact: true)
      expect(@download_directory.children).to be_empty
      capture("network-error")

      click_button "PNGをダウンロード"
      saved = await_png(png)
      expect_same_preview(url)
      expect(page).to have_css("[data-photo-card-target='error']", exact_text: "", visible: :all)
      expect(page.evaluate_script("window.__downloadRequestCount")).to eq(2)
      capture("retried", preserved_png: saved)
    end
  end

  it "keeps one pending request for a normal double-click and finishes the delayed save" do
    open_card
    generate_preview
    png = preview_bytes
    intercept_download("hold-success")
    button = find_button("PNGをダウンロード")
    button.execute_script("this.scrollIntoView({block:'center'})")
    page.driver.browser.action.double_click(button.native).perform
    wait_for_flag("window.__downloadHeld === true")
    expect(page.evaluate_script("window.__downloadRequestCount")).to eq(1)
    expect(page).to have_button("PNGをダウンロード", disabled: true)
    expect(page).to have_css("[data-photo-card-target='status']", exact_text: "保存前の確認をしています。")
    expect(@download_directory.children).to be_empty
    release_download
    await_png(png)
    expect(page.evaluate_script("window.__downloadRequestCount")).to eq(1)
  end

  [ "hold-success", "hold-error" ].each do |outcome|
    it "ignores #{outcome} after settings change and keeps a newer preview intact" do
      open_card
      generate_preview
      old_png = preview_bytes
      intercept_download(outcome)
      click_button "PNGをダウンロード"
      wait_for_flag("window.__downloadHeld === true")
      uncheck "保存済みの自己紹介を表示する"
      expect(page).to have_css("[data-photo-card-target='status']", exact_text: "設定を変更しました。プレビューを作成してください。")
      generate_preview
      current_url = find("[data-photo-card-target='image']")["src"]
      current_png = preview_bytes
      expect(current_png).not_to eq(old_png)
      expect(page.evaluate_script("window.__downloadSignal.aborted")).to be(true)
      release_download
      expect_same_preview(current_url)
      expect(page).to have_css("[data-photo-card-target='status']", exact_text: "完成プレビューを確認してから保存してください。")
      expect(page).to have_css("[data-photo-card-target='error']", exact_text: "", visible: :all)
      expect(@download_directory.children).to be_empty
    end
  end

  it "discards a delayed download after leaving the card page" do
    open_card
    generate_preview
    intercept_download("hold-success")
    click_button "PNGをダウンロード"
    wait_for_flag("window.__downloadHeld === true")
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    expect(page).to have_css("main h1", text: "マイページ", exact_text: true)
    expect(page.evaluate_script("window.__downloadSignal.aborted")).to be(true)
    release_download
    expect(page).to have_current_path(my_page_path)
    expect(page).not_to have_css("[data-controller='photo-card']")
    expect(@download_directory.children).to be_empty
  end

  it "keeps the expiry notice when a pending failure arrives after the preview expires" do
    open_card
    generate_preview
    intercept_download("hold-error")
    click_button "PNGをダウンロード"
    wait_for_flag("window.__downloadHeld === true")
    page.execute_script("const originalNow = Date.now; Date.now = () => originalNow() + 16 * 60 * 1000;")
    expect(page).to have_css("[data-photo-card-target='status']", exact_text: "プレビューの期限が切れました。再生成してください。", wait: 5)
    release_download
    expect(page).to have_css("[data-photo-card-target='status']", exact_text: "プレビューの期限が切れました。再生成してください。")
    expect(page).to have_css("[data-photo-card-target='error']", exact_text: "", visible: :all)
    expect_invalidated
  end

  it "preserves an HTTP500 reason and permits the same confirmed PNG to be retried" do
    open_card
    generate_preview
    url = find("[data-photo-card-target='image']")["src"]
    png = preview_bytes
    message = "保存処理に失敗しました。もう一度お試しください。"
    intercept_download("http", status: 500, message: message)
    click_button "PNGをダウンロード"
    expect(page).to have_css("[data-photo-card-target='error']", exact_text: message)
    expect_no_progress
    expect_same_preview(url)
    expect(@download_directory.children).to be_empty
    click_button "PNGをダウンロード"
    await_png(png)
  end

  {
    403 => "この画像は保存できません。",
    410 => "プレビューの期限が切れました。再生成してください。",
    422 => "保存情報が不正です。再生成してください。"
  }.each do |status, message|
    it "retains the HTTP#{status} reason and invalidates its forbidden preview" do
      open_card
      generate_preview
      intercept_download("http", status: status, message: message)
      click_button "PNGをダウンロード"
      expect(page).to have_css("[data-photo-card-target='error']", exact_text: message)
      expect_no_progress
      expect_invalidated
    end
  end
end
