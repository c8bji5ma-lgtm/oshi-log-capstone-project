require "rails_helper"
require "tmpdir"
require_relative "../support/image_attachments"
require_relative "../support/card_images"

RSpec.describe "Profiles and photo cards in the browser", type: :system do
  include ImageAttachments
  include CardImages

  let(:user) { create(:user) }
  let(:user_oshi) { create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "カードの推しA")) }
  let(:fixture_image) { Rails.root.join("spec/fixtures/files/image.png") }

  around do |example|
    previous_registry = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    previous_forgery_protection = ApplicationController.allow_forgery_protection
    # The real card controller reads csrf_meta_tags, which Rails omits when protection is disabled.
    ApplicationController.allow_forgery_protection = true
    Dir.mktmpdir("oshilog-profile-card-system-") do |directory|
      @download_directory = Pathname.new(directory).join("downloads")
      FileUtils.mkdir_p(@download_directory)
      storage = ActiveStorage::Service::DiskService.new(root: File.join(directory, "storage"))
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      begin
        Capybara.reset_sessions!
      ensure
        begin
          @editor_driver&.quit
        ensure
          # Stop background browser downloads before removing the example's temporary files.
          @download_driver&.quit
        end
      end
    end
  ensure
    ActiveStorage::Blob.services = previous_registry
    ActiveStorage::Blob.service = previous_service
    ApplicationController.allow_forgery_protection = previous_forgery_protection
  end

  before do
    user_oshi
    @download_driver = page.driver
    # Scope Chrome's real download directory to this example, including when the driver is reused.
    @download_driver.browser.download_path = @download_directory.to_s
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

  def open_my_page
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    expect(page).to have_css("main h1", text: "マイページ", exact_text: true)
  end

  def open_card
    open_my_page
    click_link "カードを作成"
    expect(page).to have_css("main h1", text: "推し活カード作成", exact_text: true)
    initial_image = user_oshi.reload.representative_image.attached? ? "#{user_oshi.oshi.name}の代表画像" : "画像を表示しない"
    expect(page).to have_select("1. #{user_oshi.oshi.name}の画像", selected: initial_image)
  end

  def check_loaded_image(alt)
    expect(page).to have_css("img[alt='#{alt}']", wait: 10) { |image|
      image.evaluate_script("this.complete && this.naturalWidth > 0 && this.naturalHeight > 0")
    }
  end

  def generate_preview
    click_button "プレビューを作成"
    expect(page).to have_css("[role='status']", text: "完成プレビューを確認してから保存してください。", wait: 10)
    expect(page).to have_css("main h2", text: "完成プレビュー", exact_text: true)
    check_loaded_image("生成した推し活カード")
    expect(page).to have_css("img[data-photo-card-target='image'][src^='blob:']")
    expect(page).to have_button("PNGをダウンロード", disabled: false)
    expect(page).to have_css("[data-photo-card-target='error']", exact_text: "", visible: :all)
  end

  def check_invalidated_preview
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    expect(page).to have_css("img[data-photo-card-target='image']:not([src])", visible: :all)
    expect(page).to have_button("PNGをダウンロード", disabled: true, visible: :all)
  end

  def check_changed_settings
    expect(page).to have_css("[role='status']", text: "設定を変更しました。プレビューを作成してください。")
    check_invalidated_preview
  end

  def download_png
    click_button "PNGをダウンロード"
    expect(page).to have_css("[role='status']", text: "ダウンロードを開始しました。保存先をブラウザーで確認してください。", wait: 10)
    path = @download_directory.join("oshilog-card.png")
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      unless path.file? && @download_directory.glob("*.crdownload").empty?
        raise Capybara::ExpectationNotMet, "Chrome has not finished downloading the PNG"
      end
    end
    expect(File.binread(path, 8)).to eq("\x89PNG\r\n\x1a\n".b)
    image = Vips::Image.new_from_file(path.to_s)
    expect(image.width).to be_positive
    expect(image.height).to be_positive
  end

  def open_crop(frame = user_oshi)
    find("[data-crop-for='#{frame.id}']").click
    expect(page).to have_css("dialog[open]")
    expect(page).to have_button("この範囲で確定", disabled: false, wait: 10)
  end

  def zoom_to_maximum
    find("#image-crop-zoom").send_keys(:end)
    expect(page).to have_css("output", text: "3.00倍")
  end

  def preview_png
    encoded = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      fetch(document.querySelector('[data-photo-card-target="image"]').src)
        .then(response => response.blob()).then(blob => {
          const reader = new FileReader();
          reader.onload = () => done(reader.result.split(',')[1]);
          reader.readAsDataURL(blob);
        });
    JS
    Base64.strict_decode64(encoded)
  end

  it "keeps previews for cancel, Escape and unchanged confirmation, and restores confirmed edits" do
    create(:profile, user: user)
    attach_coordinates(user_oshi)
    sign_in
    open_card
    generate_preview
    original = find("[data-photo-card-target='image']")["src"]
    open_crop
    zoom_to_maximum
    click_button "キャンセル"
    expect(page).not_to have_css("dialog[open]")
    expect(find("[data-photo-card-target='image']")["src"]).to eq(original)
    expect(page).to have_button("PNGをダウンロード", disabled: false)
    expect(page.evaluate_script("document.activeElement.dataset.cropFor")).to eq(user_oshi.id.to_s)

    open_crop
    expect(find("#image-crop-zoom").value).to eq("1")
    zoom_to_maximum
    find("#image-crop-zoom").send_keys(:escape)
    expect(page).not_to have_css("dialog[open]")
    expect(find("[data-photo-card-target='image']")["src"]).to eq(original)
    open_crop
    click_button "この範囲で確定"
    expect(find("[data-photo-card-target='image']")["src"]).to eq(original)

    open_crop
    zoom_to_maximum
    find("[data-image-crop-target='viewport']").send_keys(:arrow_right, :arrow_up)
    click_button "この範囲で確定"
    check_invalidated_preview
    generate_preview
    edited = find("[data-photo-card-target='image']")["src"]
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "この範囲で確定"
    expect(find("[data-photo-card-target='image']")["src"]).to eq(edited)
    open_crop
    click_button "リセット"
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
    expect(find("[data-photo-card-target='image']")["src"]).to eq(edited)
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "リセット"
    click_button "この範囲で確定"
    check_invalidated_preview
    open_crop
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
  end

  it "applies real mouse dragging and zoom to the PNG, and downloads the exact cropped preview" do
    create(:profile, user: user)
    original_bytes = attach_coordinates(user_oshi)
    original_attachment = user_oshi.representative_image.attachment.attributes
    sign_in
    open_card
    generate_preview
    original_png = preview_png
    original_url = find("[data-photo-card-target='image']")["src"]
    open_crop
    zoom_to_maximum
    viewport = find("[data-image-crop-target='viewport']")
    viewport.execute_script("this.scrollIntoView({block: 'center'})")
    page.driver.browser.action.move_to(viewport.native).click_and_hold.move_by(45, 25).release.perform
    expect(find("[data-photo-card-target='image']", visible: :all)["src"]).to eq(original_url)
    # Capture the displayed source pixel at the frame centre independently of the
    # submitted crop values; compare it to the centre of the generated PNG.
    colour = page.evaluate_script(<<~JS)
      (() => {
      const image = document.querySelector('[data-image-crop-target="photo"]');
      const frame = document.querySelector('[data-image-crop-target="viewport"]');
      const drawn = image.getBoundingClientRect(), windowRect = frame.getBoundingClientRect();
      const x = (windowRect.left + windowRect.width / 2 - drawn.left) * image.naturalWidth / drawn.width;
      const y = (windowRect.top + windowRect.height / 2 - drawn.top) * image.naturalHeight / drawn.height;
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d'); context.drawImage(image, x, y, 1, 1, 0, 0, 1, 1);
      return Array.from(context.getImageData(0, 0, 1, 1).data).slice(0, 3);
      })()
    JS
    click_button "この範囲で確定"
    check_invalidated_preview
    generate_preview
    cropped_png = preview_png
    expect(cropped_png).not_to eq(original_png)
    actual = Vips::Image.new_from_buffer(cropped_png, "").getpoint(48 + 248, 176 + 310).take(3)
    actual.zip(colour).each { |channel, expected| expect(channel).to be_within(2).of(expected) }
    expect(actual.first).to be < 125
    download_png
    expect(File.binread(@download_directory.join("oshilog-card.png"))).to eq(cropped_png)
    expect(user_oshi.representative_image.download).to eq(original_bytes)
    expect(user_oshi.representative_image.attachment.reload.attributes).to eq(original_attachment)
  end

  it "keeps independent crops of a shared image across templates and resets only a changed source" do
    create(:profile, user: user)
    second = create(:user_oshi, user: user, oshi: create(:oshi, name: "クロップの推しB"))
    attach_coordinates(user_oshi)
    attach_coordinates(second)
    sign_in
    open_card
    check second.oshi.name, exact: true
    select "#{user_oshi.oshi.name}の代表画像", from: "2. #{second.oshi.name}の画像"
    open_crop
    zoom_to_maximum
    click_button "右へ"
    click_button "この範囲で確定"
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("1")
    find("#image-crop-zoom").send_keys(:end, :arrow_left)
    expect(page).to have_css("output", text: "2.99倍")
    click_button "左へ"
    click_button "この範囲で確定"
    generate_preview
    png = Vips::Image.new_from_buffer(preview_png, "")
    expect(png.getpoint(580, 436).first).to be < png.getpoint(1020, 436).first

    choose "思い出・活動履歴重視", exact: true
    choose "ビジュアル重視", exact: true
    check_invalidated_preview
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("2.99")
    click_button "キャンセル"
    select "#{second.oshi.name}の代表画像", from: "2. #{second.oshi.name}の画像"
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    select "画像を表示しない", from: "1. #{user_oshi.oshi.name}の画像"
    expect(find("[data-crop-for='#{user_oshi.id}']")).to be_disabled
  end

  it "disables editing for absent images and reports a missing original in the modal" do
    create(:profile, user: user)
    sign_in
    open_card
    expect(find("[data-crop-for='#{user_oshi.id}']")).to be_disabled
    attach_coordinates(user_oshi)
    user_oshi.representative_image.blob.service.delete(user_oshi.representative_image.blob.key)
    open_card
    find("[data-crop-for='#{user_oshi.id}']").click
    within("dialog") do
      expect(page).to have_css("[role='alert']", text: "画像未登録とは異なる状態", wait: 10)
      expect(page).to have_button("この範囲で確定", disabled: true)
      click_button "キャンセル"
    end
    check_invalidated_preview
  end

  it "cancels a draft on template switch or inactivity and discards confirmed crops on navigation" do
    create(:profile, user: user)
    attach_coordinates(user_oshi)
    sign_in
    open_card
    open_crop
    zoom_to_maximum
    page.execute_script(<<~JS)
      const choice = document.querySelector('input[name="template"][value="data"]');
      choice.checked = true; choice.dispatchEvent(new Event('change', {bubbles: true}));
    JS
    expect(page).not_to have_css("dialog[open]")
    choose "ビジュアル重視", exact: true
    open_crop
    expect(find("#image-crop-zoom").value).to eq("1")
    zoom_to_maximum
    click_button "この範囲で確定"
    open_card
    open_crop
    expect(find("#image-crop-zoom").value).to eq("1")
    zoom_to_maximum
    page.execute_script("const originalNow = Date.now; Date.now = () => originalNow() + 30 * 60 * 1000;")
    expect(page).not_to have_css("dialog[open]", wait: 5)
    expect(page).to have_css("[data-photo-card-target='status']", text: "30分間操作がなかったため破棄しました。")
    check_invalidated_preview
  end

  it "contains focus and supports keyboard and real touch dragging in a narrow modal" do
    create(:profile, user: user)
    attach_coordinates(user_oshi, orientation: 6)
    page.current_window.resize_to(375, 812)
    sign_in
    open_card
    open_crop
    expect(find("[data-image-crop-target='photo']").evaluate_script("[this.naturalWidth, this.naturalHeight]")).to eq([ 600, 900 ])
    expect(page.evaluate_script("document.querySelector('dialog').matches(':modal')")).to be(true)
    viewport = find("[data-image-crop-target='viewport']")
    expect(viewport.rect.width.to_f / viewport.rect.height).to be_within(0.01).of(0.8)
    expect(viewport.evaluate_script(<<~JS)).to be(true)
      (() => {
        const frame = this.getBoundingClientRect();
        const image = this.querySelector('img').getBoundingClientRect();
        return image.left <= frame.left + 0.02 && image.top <= frame.top + 0.02 &&
          image.right >= frame.right - 0.02 && image.bottom >= frame.bottom - 0.02;
      })()
    JS
    zoom_to_maximum
    viewport.send_keys(:arrow_left, :arrow_down)
    12.times { page.driver.browser.action.send_keys(:tab).perform }
    expect(page.evaluate_script("Boolean(document.activeElement.closest('dialog'))")).to be(true)
    before = find("[data-image-crop-target='photo']")["style"]
    viewport.execute_script("this.scrollIntoView({block: 'center'})")
    rect = viewport.rect
    # Chrome DevTools delivers touch input through the browser's pointer pipeline.
    point = viewport.evaluate_script("(() => { const r = this.getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2}; })()")
    browser = page.driver.browser
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: point["x"], y: point["y"], id: 1 } ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove", touchPoints: [ { x: point["x"] + 25, y: point["y"] + 15, id: 1 } ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    expect(find("[data-image-crop-target='photo']")["style"]).not_to eq(before)
    first = { x: point["x"], y: point["y"], id: 1 }
    second = { x: point["x"] + 5, y: point["y"] + 5, id: 2 }
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ first ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ first, second ])
    before_second_finger = find("[data-image-crop-target='photo']")["style"]
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove", touchPoints: [ first, second.merge(x: point["x"] + 35) ])
    expect(find("[data-image-crop-target='photo']")["style"]).to eq(before_second_finger)
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchCancel", touchPoints: [])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ first ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove", touchPoints: [ first.merge(x: point["x"] - 20) ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    expect(find("[data-image-crop-target='photo']")["style"]).not_to eq(before_second_finger)
    expect(rect.width).to be <= 375
    expect(page.evaluate_script("(() => { const d = document.querySelector('dialog'); return d.scrollWidth <= d.clientWidth && d.getBoundingClientRect().height <= window.innerHeight; })()")).to be(true)
    click_button "この範囲で確定"
    generate_preview
    download_png
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  it "never restores a held generation response after a crop is confirmed and a new preview is generated" do
    create(:profile, user: user)
    attach_coordinates(user_oshi)
    sign_in
    open_card
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window);
      window.fetch = async (...args) => {
        const response = await originalFetch(...args);
        if (args[0] === #{card_path.to_json} && !window.cardResponseHeld) {
          window.cardResponseHeld = true;
          const blob = await response.blob();
          await new Promise(resolve => { window.releaseCardResponse = resolve; });
          window.releasingOldCard = true;
          return new Response(blob, {status: response.status, headers: response.headers});
        }
        return response;
      };
      const originalDigest = crypto.subtle.digest.bind(crypto.subtle);
      crypto.subtle.digest = (...args) => originalDigest(...args).then(digest => {
        if (window.releasingOldCard) setTimeout(() => { window.oldCardProcessed = true; }, 0);
        return digest;
      });
    JS
    click_button "プレビューを作成"
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("typeof window.releaseCardResponse === 'function'")
    end
    open_crop
    zoom_to_maximum
    click_button "この範囲で確定"
    generate_preview
    latest_url = find("[data-photo-card-target='image']")["src"]
    latest_png = preview_png
    page.execute_script("window.releaseCardResponse()")
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("window.oldCardProcessed === true")
    end
    expect(find("[data-photo-card-target='image']")["src"]).to eq(latest_url)
    expect(preview_png).to eq(latest_png)
  end

  it "starts with photo and keeps each template's settings independently while discarding previous previews" do
    create(:profile, user: user)
    second = create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "設定を保持する推し"))
    attach_coordinates(second)
    memory = create(:activity, user: user, occurred_on: Date.current)
    sign_in
    open_card
    expect(page).to have_checked_field("ビジュアル重視", exact: true)
    expect(page).to have_css("#card-settings-photo")
    expect(page).not_to have_css("#card-settings-memories, #card-settings-data")

    # Re-select the first oshi to verify selection order as well as checkbox values.
    check second.oshi.name, exact: true
    uncheck user_oshi.oshi.name, exact: true
    check user_oshi.oshi.name, exact: true
    select "画像を表示しない", from: "1. #{second.oshi.name}の画像"
    select "#{second.oshi.name}の代表画像", from: "2. #{user_oshi.oshi.name}の画像"
    uncheck "保存済みの自己紹介を表示する"
    generate_preview

    choose "思い出・活動履歴重視", exact: true
    check_invalidated_preview
    within("#card-settings-memories") do
      expect(page).to have_select("1. 掲載する活動", selected: "#{memory.occurred_on.strftime('%Y.%m.%d')} #{memory.title}")
      expect(page).not_to have_field("保存済みの自己紹介を表示する")
      click_button "掲載から外す"
      expect(page).to have_button("プレビューを作成", disabled: true)
    end
    choose "データ可視化重視", exact: true
    expect(page).not_to have_css("#card-settings-photo, #card-settings-memories")
    within("#card-settings-data") do
      expect(page).to have_select("集計対象", selected: "すべての推し")
      select second.oshi.name, from: "集計対象"
      expect(page).to have_button("プレビューを作成", disabled: false)
    end
    choose "思い出・活動履歴重視", exact: true
    within("#card-settings-memories") { expect(page).not_to have_select("1. 掲載する活動") }
    choose "ビジュアル重視", exact: true
    expect(page).to have_checked_field(user_oshi.oshi.name, exact: true)
    expect(page).to have_checked_field(second.oshi.name, exact: true)
    expect(page).to have_select("1. #{second.oshi.name}の画像", selected: "画像を表示しない")
    expect(page).to have_select("2. #{user_oshi.oshi.name}の画像", selected: "#{second.oshi.name}の代表画像")
    expect(page).to have_unchecked_field("保存済みの自己紹介を表示する")
    check_invalidated_preview
    generate_preview
    download_png
  end

  it "never generates a data card while its options are unavailable, including a submitted form" do
    create(:profile, user: user)
    sign_in
    open_card
    page.execute_script(<<~JS)
      window.cardRequests = 0;
      const originalFetch = window.fetch.bind(window);
      window.fetch = (...args) => {
        if (args[0] === #{statistics_card_path.to_json}) return Promise.reject(new TypeError('offline'));
        if (args[0] === #{card_path.to_json}) window.cardRequests += 1;
        return originalFetch(...args);
      };
    JS
    choose "データ可視化重視", exact: true
    within("#card-settings-data") do
      expect(page).to have_text("選択肢を取得できません")
      expect(page).to have_button("プレビューを作成", disabled: true)
      find("form").execute_script("this.requestSubmit()")
    end
    check_invalidated_preview
    expect(page.evaluate_script("window.cardRequests")).to eq(0)
    expect(@download_directory.children).to be_empty
  end

  it "shows and switches templates with no registered oshis" do
    user_oshi.destroy!
    create(:profile, user: user)
    sign_in
    open_my_page
    click_link "カードを作成"
    expect(page).to have_checked_field("ビジュアル重視", exact: true)
    expect(page).to have_link("推しを登録")
    expect(page).to have_button("プレビューを作成", disabled: true)
    choose "データ可視化重視", exact: true
    expect(page).to have_select("集計対象", options: [ "すべての推し" ])
    expect(page).to have_button("プレビューを作成", disabled: false)
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_css("#card-settings-memories", text: "掲載できる活動記録がありません")
    choose "ビジュアル重視", exact: true
    expect(page).to have_button("プレビューを作成", disabled: true)
    check_invalidated_preview
    expect(user.user_oshis).to be_empty
  end

  it "discards all template settings on navigation and restores initial settings on return" do
    profile = create(:profile, user: user)
    original = profile.attributes
    sign_in
    open_card
    select "画像を表示しない", from: "1. #{user_oshi.oshi.name}の画像"
    uncheck "保存済みの自己紹介を表示する"
    generate_preview
    choose "思い出・活動履歴重視", exact: true
    expect(page).not_to have_field("保存済みの自己紹介を表示する")
    choose "データ可視化重視", exact: true
    select user_oshi.oshi.name, from: "集計対象"
    open_card
    expect(page).to have_checked_field("ビジュアル重視", exact: true)
    expect(page).to have_checked_field("保存済みの自己紹介を表示する")
    check_invalidated_preview
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_text("掲載できる活動記録がありません")
    expect(page).not_to have_field("保存済みの自己紹介を表示する")
    choose "データ可視化重視", exact: true
    expect(page).to have_select("集計対象", selected: "すべての推し")
    expect(profile.reload.attributes).to eq(original)
  end

  it "expires a photo preview after fifteen minutes and permits regenerating it" do
    create(:profile, user: user)
    sign_in
    open_card
    generate_preview
    page.execute_script("window.cardOriginalNow = Date.now; Date.now = () => window.cardOriginalNow() + 15 * 60 * 1000;")
    expect(page).to have_css("[role='status']", text: "プレビューの期限が切れました。再生成してください。", wait: 5)
    check_invalidated_preview
    expect(page).to have_button("プレビューを作成", disabled: false)
    page.execute_script("Date.now = window.cardOriginalNow; delete window.cardOriginalNow;")
    generate_preview
  end

  it "discards every template's settings and preview after thirty minutes of inactivity" do
    create(:profile, user: user)
    memory = create(:activity, user: user, occurred_on: Date.current)
    sign_in
    open_card
    uncheck "保存済みの自己紹介を表示する"
    generate_preview
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_select("1. 掲載する活動", selected: memory_choice(memory))
    choose "データ可視化重視", exact: true
    select user_oshi.oshi.name, from: "集計対象"
    page.execute_script("const originalNow = Date.now; Date.now = () => originalNow() + 30 * 60 * 1000;")
    expect(page).to have_css("[role='status']", text: "30分間操作がなかったため破棄しました。ページを開き直してください。", wait: 5)
    check_invalidated_preview
    expect(page).to have_checked_field("ビジュアル重視", disabled: true, exact: true)
    expect(page).to have_button("プレビューを作成", disabled: true)
    expect(page).not_to have_css("[data-frame-source]", visible: :all)
    expect(page.all("input[name='show_introduction']", visible: :all).map(&:checked?)).to eq([ true ])
    expect(page.all("input[name='show_introduction']", visible: :all).map(&:disabled?)).to eq([ true ])
    expect(page).to have_css("[data-photo-card-target='memoryFrames']:empty", visible: :all)
    expect(page).to have_select("対象年", options: [], disabled: true, visible: :all)
    expect(page).to have_select("集計対象", options: [], disabled: true, visible: :all)
    open_card
    expect(page).to have_checked_field("ビジュアル重視", disabled: false, exact: true)
    expect(page).to have_button("プレビューを作成", disabled: false)
  end

  it "supports native keyboard template selection without horizontal overflow on a narrow screen" do
    create(:profile, user: user)
    page.current_window.resize_to(375, 900)
    sign_in
    open_card
    find("input[name='template'][value='photo']").send_keys(:arrow_right)
    expect(page).to have_checked_field("思い出・活動履歴重視", exact: true)
    expect(page).to have_css("#card-settings-memories")
    find("input[name='template'][value='memories']").send_keys(:arrow_right)
    expect(page).to have_checked_field("データ可視化重視", exact: true)
    expect(page).to have_css("#card-settings-data")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    page.all(".card-template-choice").each do |choice|
      expect(choice.rect.height).to be >= 44
    end
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  it "saves profile text and images, generates cards for one to four oshis and downloads the PNG" do
    others = (2..4).map do |index|
      create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "カードの推し#{index}"))
    end
    sign_in
    open_my_page
    click_link "プロフィール編集"
    within("main form") do
      fill_in "表示名（必須）", with: "カード利用者"
      fill_in "自己紹介", with: "ライブと舞台を楽しんでいます。"
      attach_file "プロフィール画像", fixture_image
      click_button "プロフィールを保存"
    end
    expect(page).to have_css("[role='status']", text: "プロフィールを更新しました。")
    click_link "プロフィール編集"
    expect(page).to have_field("表示名（必須）", with: "カード利用者")
    expect(page).to have_field("自己紹介", with: "ライブと舞台を楽しんでいます。")
    check_loaded_image("現在のプロフィール画像")

    within("nav[aria-label='グローバルナビゲーション']") { click_link "推し一覧" }
    within("main section.card", text: user_oshi.oshi.name) { click_link "編集", exact: true }
    attach_file "代表画像", fixture_image
    click_button "推し情報を更新"
    expect(page).to have_css("[role='status']", text: "推し情報を更新しました。")
    within("main section.card", text: user_oshi.oshi.name) { click_link "編集", exact: true }
    check_loaded_image("#{user_oshi.oshi.name}の現在の代表画像")

    open_card
    expect(page).to have_css("[data-frame-source]", count: 1)
    generate_preview
    others.each_with_index do |record, index|
      check record.oshi.name, exact: true
      expect(page).to have_css("[data-frame-source]", count: index + 2)
      check_changed_settings
      generate_preview
    end

    select "#{user_oshi.oshi.name}の代表画像", from: "2. #{others.first.oshi.name}の画像"
    expect(page).to have_select("2. #{others.first.oshi.name}の画像", selected: "#{user_oshi.oshi.name}の代表画像")
    check_changed_settings
    generate_preview
    select "画像を表示しない", from: "1. #{user_oshi.oshi.name}の画像"
    check_changed_settings
    generate_preview
    uncheck "保存済みの自己紹介を表示する"
    check_changed_settings
    generate_preview
    download_png

    open_card
    expect(page).to have_checked_field(user_oshi.oshi.name, exact: true)
    expect(page).to have_css("[data-frame-source]", count: 1)
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    expect(page).to have_css("img[data-photo-card-target='image']:not([src])", visible: :all)
  end

  it "invalidates an old preview at download after source data is edited in another browser session" do
    create(:profile, user: user)
    sign_in
    open_card
    generate_preview

    Capybara.using_session(:profile_editor) do
      @editor_driver = page.driver
      sign_in
      open_my_page
      click_link "プロフィール編集"
      fill_in "表示名（必須）", with: "別画面で更新した表示名"
      click_button "プロフィールを保存"
      expect(page).to have_css("[role='status']", text: "プロフィールを更新しました。")
    end

    click_button "PNGをダウンロード"
    expect(page).to have_css("[role='alert']", text: "元データまたは画像が変更されたか、取得できません。再生成してください。", wait: 10)
    check_invalidated_preview
    expect(@download_directory.children).to be_empty
    generate_preview
    download_png
  end

  it "allows a visible preview and download when no representative image is registered" do
    create(:profile, user: user)
    sign_in
    open_card
    expect(page).to have_text("画像未登録でも作成できます。")
    generate_preview
    download_png
  end

  it "reports an unreadable registered image and recovers when that image is explicitly switched off" do
    create(:profile, user: user)
    user_oshi.representative_image.attach(image_upload)
    # Simulate loss of an original only in this example's isolated storage; there is no UI for this fault.
    blob = user_oshi.representative_image.blob
    blob.service.delete(blob.key)
    sign_in
    open_card
    click_button "プレビューを作成"
    expect(page).to have_css("[role='alert']", text: "登録画像を読み取れません。未登録とは異なる状態です。画像を確認してください。", wait: 10)
    check_invalidated_preview
    expect(@download_directory.children).to be_empty

    select "画像を表示しない", from: "1. #{user_oshi.oshi.name}の画像"
    check_changed_settings
    generate_preview
    download_png
  end
  def memory_choice(activity)
    "#{activity.occurred_on.strftime('%Y.%m.%d')} #{activity.title}"
  end

  def open_memory_crop(activity)
    find("[data-memory-crop][data-activity-id='#{activity.id}']").click
    expect(page).to have_css("dialog[open]")
    expect(page).to have_button("この範囲で確定", disabled: false, wait: 10)
  end

  def attach_memory_photo(activity, **options)
    bytes = coordinate_image(**options)
    activity.images.attach(io: StringIO.new(bytes), filename: options[:orientation] ? "oriented.jpg" : "coordinates.png")
    bytes
  end

  it "initially selects the latest three eligible activities, supports replacing and reordering, and restores template state" do
    create(:profile, user: user)
    timestamp = Time.current.change(usec: 0)
    old = create(:activity, user: user, occurred_on: Date.current - 1)
    first = create(:activity, user: user, occurred_on: Date.current, created_at: timestamp)
    second = create(:activity, user: user, occurred_on: Date.current, created_at: timestamp)
    newest = create(:activity, user: user, occurred_on: Date.current, created_at: timestamp + 1)
    future = create(:activity, user: user, occurred_on: Date.current + 1)
    foreign = create(:activity, occurred_on: Date.current)
    sign_in
    open_card
    choose "思い出・活動履歴重視", exact: true
    [ newest, second, first ].each_with_index do |activity, index|
      expect(page).to have_select("#{index + 1}. 掲載する活動", selected: memory_choice(activity))
    end
    expect(page).not_to have_select("4. 掲載する活動")
    expect(find("#memory-activity-#{newest.id}").all("option").map(&:text)).not_to include(memory_choice(future), memory_choice(foreign))
    select memory_choice(old), from: "3. 掲載する活動"
    find("[data-memory-up][data-activity-id='#{old.id}']").send_keys(:enter)
    expect(page).to have_select("2. 掲載する活動", selected: memory_choice(old))
    generate_preview
    choose "データ可視化重視", exact: true
    check_invalidated_preview
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_select("2. 掲載する活動", selected: memory_choice(old))
    expect(page).to have_select("3. 掲載する活動", selected: memory_choice(second))
    generate_preview
    # An unchanged selection event leaves the completed preview intact.
    url = find("[data-photo-card-target='image']")["src"]
    find("#memory-activity-#{old.id}").execute_script("this.dispatchEvent(new Event('change', {bubbles:true}))")
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    find("[data-memory-remove][data-activity-id='#{old.id}']").click
    check_invalidated_preview
    expect(page).not_to have_select("3. 掲載する活動")
    generate_preview
    find("[data-memory-remove][data-activity-id='#{second.id}']").click
    generate_preview
    download_png
  end

  it "keeps per-activity photos and crops through reordering and template changes, resets only a changed photo and matches the cropped PNG" do
    create(:profile, user: user)
    first = create(:activity, user: user, occurred_on: Date.current)
    original = attach_memory_photo(first, orientation: 6)
    attach_memory_photo(first)
    second = create(:activity, user: user, occurred_on: Date.current - 1)
    attach_memory_photo(second)
    sign_in
    open_card
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_select("1. 活動の写真", selected: "写真1")
    generate_preview
    url = find("[data-photo-card-target='image']")["src"]
    open_memory_crop(first)
    zoom_to_maximum
    click_button "キャンセル"
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    open_memory_crop(first)
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "この範囲で確定"
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    open_memory_crop(first)
    zoom_to_maximum
    viewport = find("[data-image-crop-target='viewport']")
    viewport.execute_script("this.scrollIntoView({block: 'center'})")
    page.driver.browser.action.move_to(viewport.native).click_and_hold.move_by(35, 20).release.perform
    colour = page.evaluate_script(<<~JS)
      (() => {
        const photo = document.querySelector('[data-image-crop-target="photo"]');
        const viewport = document.querySelector('[data-image-crop-target="viewport"]').getBoundingClientRect();
        const bounds = photo.getBoundingClientRect();
        const canvas = document.createElement('canvas'); canvas.width = photo.naturalWidth; canvas.height = photo.naturalHeight;
        const context = canvas.getContext('2d'); context.drawImage(photo,0,0);
        const x = (viewport.left + viewport.width/2 - bounds.left)*photo.naturalWidth/bounds.width;
        const y = (viewport.top + viewport.height/2 - bounds.top)*photo.naturalHeight/bounds.height;
        return Array.from(context.getImageData(Math.floor(x),Math.floor(y),1,1).data).slice(0,3);
      })()
    JS
    click_button "この範囲で確定"
    check_invalidated_preview
    generate_preview
    png = preview_png
    pixel = Vips::Image.new_from_buffer(png, "").getpoint(552, 414).take(3)
    pixel.zip(colour).each { |actual, expected| expect(actual).to be_within(2).of(expected) }
    open_memory_crop(first)
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    find("[data-memory-down][data-activity-id='#{first.id}']").click
    choose "ビジュアル重視", exact: true
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_select("2. 掲載する活動", selected: memory_choice(first))
    open_memory_crop(first)
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "リセット"
    click_button "キャンセル"
    open_memory_crop(first)
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    select "写真2", from: "2. 活動の写真"
    open_memory_crop(first)
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
    generate_preview
    png = preview_png
    download_png
    expect(File.binread(@download_directory.join("oshilog-card.png"))).to eq(png)
    expect(first.images_attachments.order(:id).first.blob.download).to eq(original)
    expect(@download_directory.children.map(&:basename).map(&:to_s)).to eq([ "oshilog-card.png" ])
  end

  it "distinguishes no activity, no photo and an unreadable photo, and retries a failed candidate request" do
    create(:profile, user: user)
    create(:activity, user: user, occurred_on: Date.current + 1)
    sign_in
    open_card
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_text("掲載できる活動記録がありません")
    expect(page).to have_link("活動を登録", href: new_activity_path)
    expect(page).to have_button("プレビューを作成", disabled: true)
    activity = create(:activity, user: user, occurred_on: Date.current)
    visit new_card_path
    page.execute_script(<<~JS)
      const original = window.fetch.bind(window); let failed = false;
      window.fetch = (...args) => {
        if (args[0] === #{memories_card_path.to_json} && !failed) { failed = true; return Promise.reject(new TypeError('offline')); }
        return original(...args);
      };
    JS
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_text("活動記録を取得できません")
    click_button "活動記録を再読み込み"
    expect(page).to have_select("1. 活動の写真", selected: "写真なし（代替表示）", disabled: true)
    expect(page).to have_button("画像を調整", disabled: true)
    generate_preview
    attach_memory_photo(activity)
    blob = activity.images.first.blob
    File.unlink(blob.service.path_for(blob.key))
    visit new_card_path
    choose "思い出・活動履歴重視", exact: true
    find("[data-memory-crop][data-activity-id='#{activity.id}']").click
    expect(page).to have_css("dialog [role='alert']", text: "登録画像を読み取れません")
    expect(page).to have_button("この範囲で確定", disabled: true)
    click_button "キャンセル"
    click_button "プレビューを作成"
    expect(page).to have_css("[data-photo-card-target='error']", text: "未登録とは異なる状態", wait: 10)
    check_invalidated_preview
  end

  it "retains memory settings at fifteen minutes but clears drafts and selections on inactivity or navigation" do
    create(:profile, user: user)
    activity = create(:activity, user: user, occurred_on: Date.current)
    attach_memory_photo(activity)
    sign_in
    open_card
    choose "思い出・活動履歴重視", exact: true
    open_memory_crop(activity)
    zoom_to_maximum
    click_button "この範囲で確定"
    generate_preview
    page.execute_script("window.originalMemoryNow = Date.now; Date.now = () => window.originalMemoryNow() + 15*60*1000")
    expect(page).to have_css("[data-photo-card-target='status']", text: "プレビューの期限が切れました", wait: 5)
    check_invalidated_preview
    open_memory_crop(activity)
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    page.execute_script("Date.now = window.originalMemoryNow")
    generate_preview
    open_memory_crop(activity)
    page.execute_script("Date.now = () => window.originalMemoryNow() + 31*60*1000")
    expect(page).to have_css("[data-photo-card-target='status']", text: "30分間操作がなかった", wait: 5)
    expect(page).not_to have_css("dialog[open]")
    expect(page).not_to have_css("[data-memory-activity]", visible: :all)
    expect(page).to have_css("[data-photo-card-target='memoryFrames']:empty", visible: :all)
    visit new_card_path
    choose "思い出・活動履歴重視", exact: true
    open_memory_crop(activity)
    expect(find("#image-crop-zoom").value).to eq("1")
    zoom_to_maximum
    # Programmatic switches also discard the unfinished modal draft.
    page.execute_script("const radio=document.querySelector('input[value=photo]');radio.checked=true;radio.dispatchEvent(new Event('change',{bubbles:true}))")
    expect(page).not_to have_css("dialog[open]")
    choose "思い出・活動履歴重視", exact: true
    open_memory_crop(activity)
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
  end

  it "discards a held memory generation response after switching templates and keeps a newer preview" do
    create(:profile, user: user)
    create(:activity, user: user, occurred_on: Date.current)
    sign_in
    open_card
    choose "思い出・活動履歴重視", exact: true
    expect(page).to have_button("プレビューを作成", disabled: false)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window);
      window.fetch = async (...args) => {
        const response = await originalFetch(...args);
        if (args[0] === #{card_path.to_json} && !window.memoryHeld) {
          window.memoryHeld = true;
          const blob = await response.blob();
          await new Promise(resolve => { window.releaseMemory = resolve; });
          window.releasingMemory = true;
          return new Response(blob, {status:response.status, headers:response.headers});
        }
        return response;
      };
      const originalDigest = crypto.subtle.digest.bind(crypto.subtle);
      crypto.subtle.digest = (...args) => originalDigest(...args).then(digest => {
        if (window.releasingMemory) setTimeout(() => { window.oldMemoryProcessed = true; },0);
        return digest;
      });
    JS
    click_button "プレビューを作成"
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("typeof window.releaseMemory === 'function'")
    end
    choose "ビジュアル重視", exact: true
    generate_preview
    png = preview_png
    url = find("[data-photo-card-target='image']")["src"]
    page.execute_script("window.releaseMemory()")
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("window.oldMemoryProcessed === true")
    end
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    expect(preview_png).to eq(png)
    choose "思い出・活動履歴重視", exact: true
    check_invalidated_preview
    generate_preview
  end

  it "selects the current data year and all oshis, includes ended registrations, and restores data settings independently" do
    create(:profile, user: user)
    ended = create(:user_oshi, user: user, ended_period: "2025")
    current_year = Date.current.year
    past_year = (current_year - 1).to_s
    future_year = (current_year + 1).to_s
    create(:activity, user: user, occurred_on: Date.new(current_year - 1, 12, 31), amount: 1234)
    create(:activity, user: user, occurred_on: Date.new(current_year + 1, 1, 1), amount: 90000)
    current = build(:activity, :without_oshis, user: user, occurred_on: Date.current, amount: 500)
    Activities::Save.call(activity: current, oshi_ids: [ user_oshi.oshi_id, ended.oshi_id ])
    original = user.profile.reload.attributes
    sign_in
    open_card
    choose "データ可視化重視", exact: true
    expect(page).to have_select("対象年", selected: "#{current_year}年", options: [ "#{future_year}年", "#{current_year}年", "#{past_year}年" ])
    expect(page).to have_select("集計対象", selected: "すべての推し", options: [ "すべての推し", user_oshi.oshi.name, ended.oshi.name ])
    expect(page).not_to have_field("保存済みの自己紹介を表示する")
    generate_preview
    expected = Cards::Data.new(user: user, year: current_year.to_s, oshi_id: "").render
    expect(preview_png).to eq(expected)
    url = find("[data-photo-card-target='image']")["src"]
    find("#card-data-year").execute_script("this.dispatchEvent(new Event('change',{bubbles:true}))")
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    select ended.oshi.name, from: "集計対象"
    check_invalidated_preview
    generate_preview
    selected = Cards::Data.new(user: user, year: current_year.to_s, oshi_id: ended.oshi_id.to_s).render
    expect(preview_png).to eq(selected)
    expect(selected).not_to eq(expected)
    select "#{past_year}年", from: "対象年"
    generate_preview
    choose "思い出・活動履歴重視", exact: true
    check_invalidated_preview
    choose "データ可視化重視", exact: true
    expect(page).to have_select("対象年", selected: "#{past_year}年")
    expect(page).to have_select("集計対象", selected: ended.oshi.name)
    select "#{future_year}年", from: "対象年"
    generate_preview
    future = Cards::Data.new(user: user, year: future_year, oshi_id: ended.oshi_id.to_s).render
    expect(preview_png).to eq(future)
    download_png
    expect(File.binread(@download_directory.join("oshilog-card.png"))).to eq(future)
    expect(user.profile.reload.attributes).to eq(original)
  end

  it "generates a zero-data card with no oshis, retries options, retains expired settings and discards them on inactivity and navigation" do
    user_oshi.destroy!
    create(:profile, user: user)
    sign_in
    visit new_card_path
    page.execute_script(<<~JS)
      const original = window.fetch.bind(window); let failed = false;
      window.fetch = (...args) => {
        if (args[0] === #{statistics_card_path.to_json} && !failed) { failed = true; return Promise.reject(new TypeError('offline')); }
        return original(...args);
      };
    JS
    choose "データ可視化重視", exact: true
    expect(page).to have_text("選択肢を取得できません")
    click_button "選択肢を再読み込み"
    expect(page).to have_select("対象年", selected: "#{Date.current.year}年")
    expect(page).to have_select("集計対象", options: [ "すべての推し" ])
    generate_preview
    png = preview_png
    download_png
    expect(File.binread(@download_directory.join("oshilog-card.png"))).to eq(png)
    expect(@download_directory.children.map { |path| path.basename.to_s }).to eq([ "oshilog-card.png" ])
    page.execute_script("window.dataOriginalNow=Date.now;Date.now=()=>window.dataOriginalNow()+15*60*1000")
    expect(page).to have_css("[data-photo-card-target='status']", text: "プレビューの期限が切れました", wait: 5)
    check_invalidated_preview
    expect(page).to have_select("対象年", selected: "#{Date.current.year}年")
    expect(page).to have_button("プレビューを作成", disabled: false)
    page.execute_script("Date.now=window.dataOriginalNow")
    generate_preview
    page.execute_script("Date.now=()=>window.dataOriginalNow()+31*60*1000")
    expect(page).to have_css("[data-photo-card-target='status']", text: "30分間操作がなかった", wait: 5)
    check_invalidated_preview
    expect(page).to have_select("対象年", options: [], disabled: true, visible: :all)
    expect(page).to have_select("集計対象", options: [], disabled: true, visible: :all)
    visit new_card_path
    expect(page).to have_checked_field("ビジュアル重視", exact: true)
    choose "データ可視化重視", exact: true
    expect(page).to have_select("対象年", selected: "#{Date.current.year}年")
    expect(page).to have_select("集計対象", selected: "すべての推し")
    expect(user.activities).to be_empty
    expect(user.user_oshis).to be_empty
  end

  it "rejects a stale data download after a new activity is added and permits regeneration" do
    create(:profile, user: user)
    sign_in
    open_card
    choose "データ可視化重視", exact: true
    expect(page).to have_button("プレビューを作成", disabled: false)
    generate_preview
    before = preview_png
    create(:activity, user: user, occurred_on: Date.current, amount: 1000)
    click_button "PNGをダウンロード"
    expect(page).to have_css("[data-photo-card-target='error']", text: "元データ", wait: 10)
    check_invalidated_preview
    expect(@download_directory.children).to be_empty
    generate_preview
    expect(preview_png).not_to eq(before)
    download_png
  end

  it "never revives a held data response after its settings change and a newer PNG is generated" do
    create(:profile, user: user)
    create(:activity, user: user, occurred_on: Date.new(Date.current.year - 1, 1, 1))
    sign_in
    open_card
    choose "データ可視化重視", exact: true
    expect(page).to have_button("プレビューを作成", disabled: false)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window);
      window.fetch = async (...args) => {
        const response = await originalFetch(...args);
        if (args[0] === #{card_path.to_json} && !window.dataHeld) {
          window.dataHeld = true; const blob = await response.blob();
          await new Promise(resolve => { window.releaseData = resolve; }); window.releasingData = true;
          return new Response(blob,{status:response.status,headers:response.headers});
        }
        return response;
      };
      const originalDigest=crypto.subtle.digest.bind(crypto.subtle);
      crypto.subtle.digest=(...args)=>originalDigest(...args).then(digest=>{
        if(window.releasingData)setTimeout(()=>{window.oldDataProcessed=true},0);
        return digest;
      });
    JS
    click_button "プレビューを作成"
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("typeof window.releaseData === 'function'")
    end
    select "#{Date.current.year - 1}年", from: "対象年"
    check_invalidated_preview
    generate_preview
    png = preview_png
    url = find("[data-photo-card-target='image']")["src"]
    page.execute_script("window.releaseData()")
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("window.oldDataProcessed === true")
    end
    expect(find("[data-photo-card-target='image']")["src"]).to eq(url)
    expect(preview_png).to eq(png)
  end

  it "edits, saves and restores all three templates in one session without mixing images, crops or settings" do
    create(:profile, user: user)
    second = create(:user_oshi, user: user)
    bytes = attach_coordinates(user_oshi, orientation: 6)
    first = build(:activity, :without_oshis, user: user, occurred_on: Date.current, amount: 1000)
    Activities::Save.call(activity: first, oshi_ids: [ user_oshi.oshi_id ])
    attach_memory_photo(first)
    first.images.attach(user_oshi.representative_image.blob)
    other = build(:activity, :without_oshis, user: user, occurred_on: Date.current - 1)
    Activities::Save.call(activity: other, oshi_ids: [ second.oshi_id ])
    past = build(:activity, :without_oshis, user: user, occurred_on: Date.new(Date.current.year - 1, 12, 31), amount: 2000)
    Activities::Save.call(activity: past, oshi_ids: [ second.oshi_id ])
    original_profile = user.profile.reload.attributes
    original_blob = user_oshi.representative_image.blob.reload.attributes
    models = [ Profile, UserOshi, Activity, ActivityOshi, ActiveStorage::Blob, ActiveStorage::Attachment ]
    counts = models.map(&:count)
    saved = []
    downloaded_paths = []
    verified_download = lambda do
      png = preview_png
      directory = @download_directory.join("template-#{saved.length + 1}")
      FileUtils.mkdir_p(directory)
      @download_driver.browser.download_path = directory.to_s
      click_button "PNGをダウンロード"
      expect(page).to have_css("[data-photo-card-target='status']", text: "ダウンロードを開始しました", wait: 10)
      downloaded = nil
      page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
        fresh = directory.children
        unless fresh.one? && fresh.first.extname == ".png" && directory.glob("*.crdownload").empty?
          raise Capybara::ExpectationNotMet, "Expected exactly one new completed PNG download"
        end
        downloaded = fresh.first
      end
      expect(File.binread(downloaded)).to eq(png)
      expect(File.binread(downloaded, 8)).to eq(Cards::Photo::PNG_SIGNATURE)
      decoded = Vips::Image.new_from_file(downloaded.to_s)
      expect([ decoded.width, decoded.height ]).to eq([ 1600, 1000 ])
      saved << png
      downloaded_paths << downloaded
    end
    sign_in
    open_card
    check second.oshi.name, exact: true
    select "画像を表示しない", from: "2. #{second.oshi.name}の画像"
    uncheck "保存済みの自己紹介を表示する"
    open_crop
    zoom_to_maximum
    find("[data-image-crop-target='viewport']").send_keys(:arrow_left)
    click_button "この範囲で確定"
    generate_preview
    verified_download.call

    choose "思い出・活動履歴重視", exact: true
    check_invalidated_preview
    expect(page).to have_select("1. 掲載する活動", selected: memory_choice(first))
    select "写真2", from: "1. 活動の写真"
    open_memory_crop(first)
    find("#image-crop-zoom").send_keys(:home, *Array.new(50, :arrow_right))
    expect(find("#image-crop-zoom").value).to eq("1.5")
    find("[data-image-crop-target='viewport']").send_keys(:arrow_right)
    click_button "この範囲で確定"
    find("[data-memory-down][data-activity-id='#{first.id}']").click
    generate_preview
    verified_download.call

    choose "データ可視化重視", exact: true
    check_invalidated_preview
    select "#{Date.current.year - 1}年", from: "対象年"
    select second.oshi.name, from: "集計対象"
    generate_preview
    verified_download.call

    choose "ビジュアル重視", exact: true
    check_invalidated_preview
    expect(page).to have_checked_field(user_oshi.oshi.name, exact: true)
    expect(page).to have_checked_field(second.oshi.name, exact: true)
    expect(page).to have_select("2. #{second.oshi.name}の画像", selected: "画像を表示しない")
    expect(page).to have_unchecked_field("保存済みの自己紹介を表示する")
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    generate_preview
    expect(preview_png).to eq(saved[0])

    choose "思い出・活動履歴重視", exact: true
    check_invalidated_preview
    expect(page).to have_select("2. 掲載する活動", selected: memory_choice(first))
    expect(page).to have_select("2. 活動の写真", selected: "写真2")
    open_memory_crop(first)
    expect(find("#image-crop-zoom").value).to eq("1.5")
    click_button "キャンセル"
    generate_preview
    expect(preview_png).to eq(saved[1])

    choose "データ可視化重視", exact: true
    check_invalidated_preview
    expect(page).to have_select("対象年", selected: "#{Date.current.year - 1}年")
    expect(page).to have_select("集計対象", selected: second.oshi.name)
    generate_preview
    expect(preview_png).to eq(saved[2])
    files = @download_directory.glob("**/*").select(&:file?)
    expect(files).to match_array(downloaded_paths)
    expect(files.map { |path| File.binread(path) }).to match_array(saved)
    expect(models.map(&:count)).to eq(counts)
    expect(user.profile.reload.attributes).to eq(original_profile)
    expect(user_oshi.representative_image.blob.reload.attributes).to eq(original_blob)
    expect(user_oshi.representative_image.download).to eq(bytes)
    expect(first.images_attachments.order(:id).last.blob.download).to eq(bytes)
  end
end
