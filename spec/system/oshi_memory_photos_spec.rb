require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Oshi memory photos on a narrow screen", type: :system do
  include ImageAttachments

  let(:user) { create(:user) }
  let(:registration) { create(:user_oshi, user: user) }
  let(:activity) do
    record = build(:activity, :without_oshis, user: user, title: "ライブの思い出")
    Activities::Save.call(activity: record, oshi_ids: [ registration.oshi_id ])
    record.images.attach(image_upload)
    record
  end
  let(:photo) { activity.images_attachments.first }

  before do
    @window = page.current_window
    @original_size = @window.size
    @window.resize_to(320, 812)
    activity
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit user_oshi_path(registration)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    @window.resize_to(*@original_size) if @original_size
  end

  def open_memory
    within("section[aria-labelledby='oshi-memory-photos-heading']") do
      image = find("img")
      image.scroll_to(:center)
      expect(image).to match_selector(:css, "img") { |img| img.evaluate_script("this.complete && this.naturalWidth > 0") }
      expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
      click_link activity.title
    end
    expect(page).to have_current_path(activity_path(activity, memory_origin: registration.id, memory_photo: photo.id))
    expect(page).to have_css("h2", exact_text: activity.title)
    image = find(".activity-memory-feature img[src='#{protected_activity_preview_path(photo)}']")
    expect(image).to match_selector(:css, "img") { |img| img.evaluate_script("this.complete && this.naturalWidth > 0") }
  end

  def watch_transitions
    page.execute_script(<<~JS)
      const start = document.startViewTransition.bind(document)
      window.memoryCapture = []
      document.startViewTransition = update => {
        const name = selector => getComputedStyle(document.querySelector(selector)).viewTransitionName
        window.memoryCapture.push(name(".memory-photo-transition-target"))
        const transition = start(async () => {
          await update()
          window.memoryCapture.push(name(".activity-memory-feature"))
        })
        transition.ready.then(() => {
          document.documentElement.dataset.memoryCaptureReady = "true"
        }, () => {})
        return transition
      }
    JS
  end

  it "animates the same thumbnail on both sides at 320px and goes back to the gallery" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "no-preference" } ])
    expect(page.evaluate_script("window.innerWidth")).to eq(320)
    watch_transitions
    open_memory
    expect(page).to have_css("html[data-memory-capture-ready='true']", visible: :all)
    expect(page.evaluate_script("window.memoryCapture")).to eq([ "activity-memory-photo", "activity-memory-photo" ])
    go_back
    expect(page).to have_current_path(user_oshi_path(registration))
    within("section[aria-labelledby='recent-oshi-activities-heading']") { click_link activity.title }
    expect(page).to have_current_path(activity_path(activity))
    expect(page).to have_no_css(".activity-memory-feature")
  end

  it "shows the same photo with reduced motion, without starting a transition" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    watch_transitions
    open_memory
    expect(page.evaluate_script("window.memoryCapture")).to eq([])
  end

  it "shows the same photo when the transition API is unavailable" do
    page.execute_script("Object.defineProperty(document, 'startViewTransition', { value: undefined, configurable: true })")
    open_memory
    expect(page).to have_no_css("html[data-memory-photo-transition]", visible: :all)
  end
end
