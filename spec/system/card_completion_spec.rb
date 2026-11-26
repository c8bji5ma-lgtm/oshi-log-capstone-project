require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Card completion", type: :system do
  include ImageAttachments

  let(:user) { create(:user) }
  let(:registration) { create(:user_oshi, user: user) }

  around do |example|
    previous = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    example.run
  ensure
    ApplicationController.allow_forgery_protection = previous
  end

  before do
    create(:profile, user: user)
    registration.representative_image.attach(image_upload)
    page.current_window.resize_to(375, 812)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit new_card_path
    expect(page).to have_button("プレビューを作成", disabled: false)
  end

  def expect_completion
    expect(page).to have_css(".card-completion h2", exact_text: "完成プレビュー", wait: 10)
    expect(page).to have_css(".card-completion img") { |image| image.evaluate_script("this.complete && this.naturalWidth > 0") }
    expect(page).to have_button("PNGをダウンロード", disabled: false)
  end

  it "shows the decoded card and moves keyboard focus to the completion heading" do
    find_button("プレビューを作成").send_keys(:enter)
    expect_completion
    expect(page.evaluate_script("document.activeElement.id")).to eq("card-completion-title")
    page.driver.browser.action.send_keys(:tab).perform
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("PNGをダウンロード")
  end

  it "keeps the preview and download unavailable if the image cannot be decoded" do
    page.execute_script(<<~JS)
      const decode = HTMLImageElement.prototype.decode;
      HTMLImageElement.prototype.decode = function () {
        if (!this.matches(".photo-card-preview")) return decode.call(this);
        return Promise.reject(new DOMException("Cannot decode", "EncodingError"));
      };
    JS
    click_button "プレビューを作成"
    expect(page).to have_css("[role='alert']", text: "完成画像を表示できませんでした。", wait: 10)
    expect(page).to have_no_css(".card-completion")
    expect(page).to have_no_button("PNGをダウンロード")
    expect(page).to have_button("プレビューを作成", disabled: false)
  end

  it "does not steal focus when the person moves on, and respects reduced motion" do
    browser = page.driver.browser
    browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    begin
      page.execute_script(<<~JS)
        const decode = HTMLImageElement.prototype.decode;
        HTMLImageElement.prototype.decode = function () {
          if (!this.matches(".photo-card-preview")) return decode.call(this);
          return new Promise((resolve, reject) => {
            window.finishCardDecode = () => decode.call(this).then(resolve, reject);
            document.body.dataset.cardDecodeHeld = "";
          });
        };
      JS
      click_button "プレビューを作成"
      expect(page).to have_css("body[data-card-decode-held]")
      expect(page).to have_no_css(".card-completion")
      skip_link = find(".skip-link", visible: :all)
      skip_link.execute_script("this.focus()")
      page.execute_script("window.finishCardDecode()")
      expect_completion
      expect(page.evaluate_script("document.activeElement.classList.contains('skip-link')")).to be(true)
      expect(page.evaluate_script("getComputedStyle(document.querySelector('.card-completion-mark')).animationName")).to eq("none")
    ensure
      browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    end
  end
end
