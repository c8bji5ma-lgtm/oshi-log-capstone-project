require "rails_helper"
require "tmpdir"
require_relative "../support/card_images"

RSpec.describe "Choosing library photos for cards in the browser", type: :system do
  include CardImages
  let(:user) { create(:user) }
  let(:record) { create(:user_oshi, user: user, oshi: create(:oshi, name: "推しA")) }

  around do |example|
    services, service = ActiveStorage::Blob.services, ActiveStorage::Blob.service
    forgery = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    Dir.mktmpdir("photo-library-browser-") do |directory|
      disk = ActiveStorage::Service::DiskService.new(root: File.join(directory, "storage"))
      disk.name = "test"
      ActiveStorage::Blob.services = { "test" => disk }
      ActiveStorage::Blob.service = disk
      @downloads = Pathname.new(directory).join("downloads")
      FileUtils.mkdir_p(@downloads)
      Capybara.using_session("photo-library-#{SecureRandom.hex(6)}") do
        begin
          example.run
        ensure
          begin
            @photo_session&.reset!
          ensure
            @photo_session&.quit
          end
        end
      end
    end
  ensure
    ActiveStorage::Blob.services, ActiveStorage::Blob.service = services, service
    ApplicationController.allow_forgery_protection = forgery
  end

  before do
    @photo_session = page
    @photo_session.driver.browser.download_path = @downloads.to_s
  end

  def open_card
    create(:profile, user: user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    expect(page).to have_current_path(root_path)
    visit new_card_path
    expect(page).to have_css("main h1", text: "推し活カード作成")
  end

  def additional_image(target = record)
    target.library_images.attach(io: StringIO.new(coordinate_image(width: 600, height: 900)), filename: "portrait.png")
    target.reload.image_library.last
  end

  def choose_image(frame, image)
    find("#card-image-source-#{frame.id}").find("option[value='#{image.id}']").select_option
  end

  def open_crop(frame = record)
    find("[data-crop-for='#{frame.id}']").click
    expect(page).to have_css("dialog[open]")
    expect(page).to have_button("この範囲で確定", disabled: false)
  end

  def generate
    click_button "プレビューを作成"
    expect(page).to have_css("[data-photo-card-target='status']", text: "完成プレビューを確認してから保存してください。", wait: 10)
    expect(page).to have_button("PNGをダウンロード", disabled: false)
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

  it "groups 120 candidates, deduplicates representatives and loads only selected originals at 1280px and 375px" do
    bytes = coordinate_image(width: 30, height: 40)
    record.library_images.attach(Array.new(30) { { io: StringIO.new(bytes), filename: "photo.png" } })
    blobs = record.reload.library_images.blobs.to_a
    records = [ record ] + Array.new(3) { |i| create(:user_oshi, user: user, oshi: create(:oshi, name: "推し#{i + 2}")) }
    records.each do |target|
      target.library_images.attach(blobs) unless target == record
      target.representative_image.attach(blobs.first)
    end
    open_card
    expect(page).to have_select("1. 推しAの画像", selected: "推しAの代表画像")
    expect(find("[data-frame-source]").all("option").size).to eq(31)
    records.drop(1).each { |target| check target.oshi.name, exact: true }
    expect(page).to have_css("[data-frame-source]", count: 4)
    choices = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('[data-frame-source]')).map(select => ({
        options: select.options.length, groups: select.querySelectorAll('optgroup').length,
        ids: Array.from(select.options).map(option => option.value)
      }))
    JS
    choices.each do |choice|
      expect(choice["options"]).to eq(121)
      expect(choice["groups"]).to eq(4)
      expect(choice["ids"].uniq.size).to eq(121)
    end
    expect(page).to have_css("[data-frame-preview]", count: 4) { |image| image.evaluate_script("this.complete && this.naturalWidth > 0") }
    paths = page.evaluate_script("performance.getEntriesByType('resource').map(entry => new URL(entry.name).pathname).filter(path => path.startsWith('/images/'))")
    expected = records.map do |target|
      target.reload
      selected = target.image_library.find { |image| image.blob_id == target.representative_image.blob_id }
      protected_image_path(selected)
    end
    expect(paths).not_to be_empty
    expect(paths - expected).to be_empty
    directory = Rails.root.join("tmp/issue70b")
    FileUtils.mkdir_p(directory)
    [ 1280, 375 ].each do |width|
      page.current_window.resize_to(width, 1024)
      find("#card-settings-photo").execute_script("this.scrollIntoView({block: 'start', behavior: 'instant'})")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      page.save_screenshot(directory.join("selection-#{width}.png"))
      open_crop
      expect(page.evaluate_script("document.querySelector('dialog').getBoundingClientRect().width <= window.innerWidth")).to be(true)
      find("#image-crop-zoom").send_keys(:end)
      find("[data-image-crop-target='viewport']").send_keys(:arrow_left, :arrow_up)
      page.save_screenshot(directory.join("library-crop-#{width}.png"))
      click_button "キャンセル"
    end
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  it "keeps different crops of the same library image through templates and downloads the identical PNG" do
    original = attach_coordinates(record)
    image = additional_image
    second = create(:user_oshi, user: user, oshi: create(:oshi, name: "推しB"))
    attach_coordinates(second)
    library_bytes = image.download
    open_card
    check second.oshi.name, exact: true
    choose_image(record, image)
    choose_image(second, image)
    open_crop
    find("#image-crop-zoom").send_keys(:end)
    click_button "右へ"
    click_button "この範囲で確定"
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("1")
    find("#image-crop-zoom").send_keys(:end, :arrow_left)
    click_button "左へ"
    click_button "この範囲で確定"
    generate
    png = preview_png
    rendered = Vips::Image.new_from_buffer(png, "")
    expect(rendered.getpoint(580, 436).first).to be < rendered.getpoint(1020, 436).first
    click_button "PNGをダウンロード"
    expect(page).to have_css("[data-photo-card-target='status']", text: "ダウンロードを開始しました。", wait: 10)
    page.document.synchronize(10, errors: [ Capybara::ExpectationNotMet ]) do
      raise Capybara::ExpectationNotMet unless @downloads.join("oshilog-card.png").file?
    end
    expect(File.binread(@downloads.join("oshilog-card.png"))).to eq(png)
    [ "思い出・活動履歴重視", "データ可視化重視", "ビジュアル重視" ].each { |template| choose template, exact: true }
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("2.99")
    click_button "キャンセル"
    choose_image(second, second.reload.image_library.first)
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
    choose_image(second, image)
    uncheck record.oshi.name, exact: true
    expect(page).to have_select("1. 推しBの画像", selected: "推しBの代表画像")
    expect(find("[data-frame-source]").all("option").map(&:value)).not_to include(image.id.to_s)
    open_crop(second)
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
    expect(record.representative_image.download).to eq(original)
    expect(image.download).to eq(library_bytes)
  end

  it "discards a stale crop confirmation even after changing away from and back to the original image" do
    attach_coordinates(record)
    image = additional_image
    open_card
    choose_image(record, image)
    open_crop
    page.execute_script(<<~JS)
      const element = document.querySelector('[data-controller="photo-card"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, 'photo-card');
      const crop = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('dialog'), 'image-crop');
      const stale = { frameId: crop.editing.frameId, sourceId: crop.editing.sourceId, crop: {x: 0.5, y: 0.5, zoom: 3} };
      const select = element.querySelector('[data-frame-source]');
      const selected = select.value;
      select.value = ''; select.dispatchEvent(new Event('change', {bubbles: true}));
      const replacement = element.querySelector('[data-frame-source]');
      replacement.value = selected; replacement.dispatchEvent(new Event('change', {bubbles: true}));
      controller.confirmCrop({detail: stale});
    JS
    expect(page).not_to have_css("dialog[open]")
    open_crop
    expect(find("#image-crop-zoom").value).to eq("1")
    click_button "キャンセル"
  end

  it "refuses a downloaded preview after library deletion and recovers with another selected image" do
    attach_coordinates(record)
    image = additional_image
    open_card
    choose_image(record, image)
    generate
    UserOshis::Save.call(user_oshi: record.reload, remove_image_id: image.id.to_s)
    click_button "PNGをダウンロード"
    expect(page).to have_css("[data-photo-card-target='error']", text: "再生成してください。", wait: 10)
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    expect(@downloads.children).to be_empty
    choose_image(record, record.reload.image_library.first)
    generate
  end

  it "starts unused when the representative is cleared while retaining selectable library images" do
    image = additional_image
    open_card
    expect(page).to have_select("1. 推しAの画像", selected: "画像を表示しない")
    expect(page).to have_button("画像を調整", disabled: true)
    generate
    choose_image(record, image)
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    open_crop
    expect(find("[data-image-crop-target='photo']")["src"]).to end_with(protected_image_path(image))
    click_button "キャンセル"
  end

  it "expires the PNG while still accepting a current library crop confirmation" do
    image = additional_image
    open_card
    choose_image(record, image)
    generate
    open_crop
    find("#image-crop-zoom").send_keys(:end)
    page.execute_script(<<~JS)
      const element = document.querySelector('[data-controller="photo-card"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, 'photo-card');
      controller.result.expiresAt = Date.now() - 1;
    JS
    click_button "この範囲で確定"
    expect(page).not_to have_css("[data-photo-card-target='preview']")
    open_crop
    expect(find("#image-crop-zoom").value).to eq("3")
    click_button "キャンセル"
  end
end
