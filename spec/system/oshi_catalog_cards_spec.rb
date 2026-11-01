require "rails_helper"
require "json"
require "base64"
require_relative "../support/started_period_picker"

RSpec.describe "Browsing registered catalog cards before search", type: :system do
  include StartedPeriodPicker
  include_context "emotion master data"

  let(:user) { create(:user) }

  def setup_catalog
    @personal = create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "00_追加済みの推し"))
    @candidate = create(:oshi, :approved, name: "01_安全な共通画像の推し")
    @pending = create(:oshi, :pending, name: "02_本人の承認待ち", created_by_user: user)
    @long = create(:oshi, :approved, name: "03_" + ("LongName" * 25))
    10.times { |index| create(:oshi, :approved, name: format("04_追加候補%02d", index)) }
    @foreign = create(:user_oshi, oshi: @candidate)
    @foreign.representative_image.attach(io: File.open(Rails.root.join("spec/fixtures/files/image.png")), filename: "private.png", content_type: "image/png")
    @private = create(:oshi, :pending, name: "他人の非公開候補", created_by_user: @foreign.user)
    create(:oshi, :rejected, name: "表示しない却下候補", created_by_user: user)
    @active_image = create(:oshi_common_image, oshi: @candidate, attribution_text: "合成画像の安全な帰属")
    @inactive_image = create(:oshi_common_image, oshi: @long, active: false, attribution_text: "表示しない無効帰属")
  end

  def login(account = user)
    visit new_user_session_path
    fill_in "user_email", with: account.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", exact_text: "ホーム")
  end

  def expect_initial_cards
    expect(page).to have_css("#oshi-search-results[data-oshi-search-state='initial'][data-oshi-search-count='12']")
    expect(page).to have_css("#oshi-search-results .oshi-catalog-card", count: 12)
    expect(page).to have_no_css("#oshi-search-results input:checked")
    expect(page).to have_text("選ぶだけでは追加されません")
    expect(page).not_to have_text(@private.name)
    expect(page).not_to have_text("表示しない却下候補")
    within("[data-catalog-oshi-id='#{@personal.oshi_id}']") { expect(page).to have_text("追加済み") }
    within("[data-catalog-oshi-id='#{@candidate.id}']") do
      expect(page).to have_text("未追加")
      expect(find("img")[:src]).to end_with(common_oshi_image_path(@active_image.image.attachment))
    end
    within("[data-catalog-oshi-id='#{@long.id}']") { expect(find("img")[:src]).to include("image_placeholder") }
    expect(page).to have_no_css("img[src$='#{protected_image_path(@foreign.representative_image.attachment)}']")
    expect(page).to have_no_css("img[src$='#{common_oshi_image_path(@inactive_image.image.attachment)}']")
  end

  def checked_catalog_ids
    page.all("#oshi-search-results input[type=radio]:checked").map(&:value)
  end

  def choose_card(record)
    within("#oshi-search-results") { choose record.name, exact: false }
    expect(checked_catalog_ids).to eq([ record.id.to_s ])
    expect(page).to have_css("[data-oshi-registration-target='status']", text: record.name)
  end

  def search(query)
    within("#oshi-existing") do
      fill_in "推しを検索", with: query
      click_button "検索", exact: true
    end
  end

  def capture_cards(width, phase, no_js: false)
    record = if no_js
      { "viewport_width" => width, "JavaScript_disabled" => true,
        "checked_ids" => checked_catalog_ids,
        "cards" => page.all("#oshi-search-results .oshi-catalog-card").size }
    else
      page.evaluate_script(<<~JS)
        (() => {
          const result=document.getElementById("oshi-search-results"),track=result.querySelector(".oshi-catalog-track");
          const selected=result.querySelector("input:checked")?.closest(".oshi-catalog-card");
          return {viewport_width:innerWidth,client_width:document.documentElement.clientWidth,
            scroll_width:document.documentElement.scrollWidth,state:result.dataset.oshiSearchState,
            candidate_ids:[...result.querySelectorAll("input[type=radio]")].map(input=>input.value),
            checked_ids:[...result.querySelectorAll("input[type=radio]:checked")].map(input=>input.value),
            track_client_width:track?.clientWidth || null,track_scroll_width:track?.scrollWidth || null,
            track_scroll_left:track?.scrollLeft || 0,
            selected_fully_visible:!selected || (selected.getBoundingClientRect().left>=track.getBoundingClientRect().left-1 && selected.getBoundingClientRect().right<=track.getBoundingClientRect().right+1),
            label_heights:[...result.querySelectorAll("label")].map(label=>label.getBoundingClientRect().height),
            active_id:document.activeElement.id,
            status:document.querySelector("[data-oshi-registration-target=status]").textContent};
        })()
      JS
    end
    unless no_js
      expect(record["viewport_width"]).to eq(width)
      expect(record["scroll_width"]).to be <= record["client_width"]
      expect(record["label_heights"]).to all(be >= 44)
      expect(record["checked_ids"].size).to be <= 1
      expect(record["selected_fully_visible"]).to be(true) if record["checked_ids"].any?
    end
    browser = page.driver.browser
    size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
    directory = Rails.root.join("tmp/oshi-catalog-cards-b-20261030-ui", ENV.fetch("OSHI_CATALOG_CAPTURE_LABEL", "local"))
    FileUtils.mkdir_p(directory)
    path = directory.join("#{width}-#{phase}.png")
    File.binwrite(path, Base64.strict_decode64(shot.fetch("data")))
    File.write(path.sub_ext(".json"), JSON.pretty_generate(record.merge("screenshot" => path.to_s)))
  end

  def activity_fields
    page.evaluate_script(<<~JS)
      (() => {
        const fields={};
        for(const id of ["activity_title","activity_place","activity_memo","activity_amount","activity_occurred_on","activity_activity_type"])fields[id]=document.getElementById(id).value;
        fields.lock_version=document.querySelector("input[name='activity[lock_version]']")?.value || null;
        fields.emotions=[...document.querySelectorAll("input[name='activity[emotion_ids][]']:checked")].map(input=>input.value);
        return fields;
      })()
    JS
  end

  def open_activity(mode, width)
    if mode == "edit"
      @activity = build(:activity, user: user, oshis_count: 0, title: "保存済みの活動")
      Activities::Save.call(activity: @activity, oshi_ids: [ @personal.oshi_id ])
    end
    page.current_window.resize_to(width, 900)
    login
    visit(mode == "edit" ? edit_activity_path(@activity) : new_activity_path)
    fill_in "activity_title", with: "カード閲覧中も残す入力"
    fill_in "activity_place", with: "合成の場所"
    fill_in "activity_memo", with: "残すメモ"
    fill_in "activity_amount", with: "0"
    fill_in "活動日（必須）", with: Date.new(2026, 10, 2)
    select "ライブ・イベント", from: "カテゴリ（必須）"
    check @personal.oshi.name, allow_label_click: true
    check "感動", allow_label_click: true
    attach_file "activity_images", [ Rails.root.join("spec/fixtures/files/image.png"), Rails.root.join("spec/fixtures/files/image.jpg") ]
    expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
    expect(page).to have_css("[data-image-upload-target='previewImages'] img", count: 2)
    @fields = activity_fields
    @activity_count = Activity.count
    @image_counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    page.execute_script(<<~JS)
      const input=document.getElementById("activity_images");
      window.catalogOriginalForm=input.form;window.catalogOriginalInput=input;
      window.catalogOriginalFiles=input.files;
      window.catalogPreviewURLs=[...document.querySelectorAll("[data-image-upload-target=previewImages] img")].map(img=>img.src);
    JS
    open_panel
  end

  def open_panel
    click_button "推しを追加", exact: true
    expect(page).to have_css("#activity-oshi-panel:not([hidden]) #oshi-search-results")
  end

  def expect_activity_preserved
    expect(activity_fields).to eq(@fields)
    expect(page.evaluate_script(<<~JS)).to be(true)
      (() => {
        const input=document.getElementById("activity_images");
        return input===window.catalogOriginalInput && input.form===window.catalogOriginalForm &&
          input.files===window.catalogOriginalFiles && input.files.length===2 &&
          JSON.stringify([...document.querySelectorAll("[data-image-upload-target=previewImages] img")].map(img=>img.src))===JSON.stringify(window.catalogPreviewURLs);
      })()
    JS
    expect(page).to have_checked_field(@personal.oshi.name, type: "checkbox", visible: :all)
    expect(Activity.count).to eq(@activity_count)
    expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(@image_counts)
  end

  [ 375, 1280 ].each do |width|
    it "browses, selects with keyboard, cancels and explicitly registers from cards at #{width}px" do
      setup_catalog
      page.current_window.resize_to(width, 900)
      login
      visit new_oshi_path
      expect_initial_cards
      counts = [ Oshi.count, UserOshi.count ]
      first = find("#oshi_id_#{@personal.oshi_id}")
      first.send_keys(:space)
      expect(page).to have_css("[data-oshi-registration-target=status]", text: "追加済み")
      first.send_keys(:arrow_right)
      expect(checked_catalog_ids).to eq([ @candidate.id.to_s ])
      expect(page.evaluate_script("document.activeElement.id")).to eq("oshi_id_#{@candidate.id}")
      choose_card(@long)
      expect(page.evaluate_script("document.querySelector('.oshi-catalog-track').scrollLeft")).to be > 0
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      search(@candidate.name)
      expect(page).to have_css("#oshi-search-results[data-oshi-search-state='results']")
      expect(page).to have_no_css(".oshi-catalog-track")
      within("form[action='#{user_oshis_path}']") do
        choose @candidate.name, exact: false
        select_started_period "2023/05"
      end
      fill_in "oshi_name", with: "手入力の登録名は保持"
      page.execute_script(<<~JS)
        window.catalogSearches=0;window.catalogOriginalFetch=window.fetch.bind(window);
        window.fetch=(input,options={})=>{
          const url=new URL(input instanceof Request?input.url:input.toString(),location.href);
          if(url.pathname===#{new_oshi_path.to_json} && options.headers?.Accept==="text/html")window.catalogSearches++;
          return window.catalogOriginalFetch(input,options);
        };
      JS
      search("")
      expect_initial_cards
      expect(page.evaluate_script("window.catalogSearches")).to eq(0)
      expect(page).to have_field("oshi_name", with: "手入力の登録名は保持")
      expect(page).to have_field("existing_user_oshi_started_period", with: "2023/05", visible: :all)
      choose_card(@long)
      capture_cards(width, "full-selected-long")
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      click_link "推し一覧へ戻る"
      expect(page).to have_css("main h1", exact_text: "推し一覧")
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      visit new_oshi_path
      choose_card(@candidate)
      within("form[action='#{user_oshis_path}']") do
        select_started_period "2023/05"
        click_button "選んだ推しを追加"
      end
      expect(page).to have_css("main h1", exact_text: "推し一覧")
      expect(user.user_oshis.find_by!(oshi: @candidate).started_period).to eq("2023/05")
      expect([ Oshi.count, UserOshi.count ]).to eq([ counts[0], counts[1] + 1 ])
    end

    it "uses cards in the #{width == 375 ? 'new' : 'edit'} activity panel without replacing fields or photos at #{width}px" do
      setup_catalog
      mode = width == 375 ? "new" : "edit"
      open_activity(mode, width)
      expect_initial_cards
      registrations = UserOshi.count
      choose_card(@long)
      capture_cards(width, "inline-#{mode}-selected")
      expect_activity_preserved
      within("#activity-oshi-panel") { find("button[data-action*='activity-oshi-panel#close']").click }
      expect(page).to have_css("#activity-oshi-panel[hidden]", visible: :all)
      expect_activity_preserved
      expect(UserOshi.count).to eq(registrations)
      open_panel
      choose_card(@candidate)
      within("#oshi-existing form[action='#{user_oshis_path}']") do
        select_started_period "2022/04"
        click_button I18n.t("ui.activity_panel.register_select")
      end
      expect(page).to have_checked_field(@candidate.name, type: "checkbox", visible: :all)
      expect_activity_preserved
      expect(user.user_oshis.find_by!(oshi: @candidate).started_period).to eq("2022/04")
      expect(UserOshi.count).to eq(registrations + 1)
      within("[data-catalog-oshi-id='#{@candidate.id}']") { expect(page).to have_text("追加済み") }
      within("#oshi-existing form[action='#{user_oshis_path}']") do
        expect(page).to have_button(I18n.t("ui.activity_panel.select"))
        click_button I18n.t("ui.activity_panel.select")
      end
      expect_activity_preserved
      expect(UserOshi.count).to eq(registrations + 1)
    end
  end

  it "distinguishes an empty initial catalog from an explicit empty search at375px" do
    create(:oshi, :pending, created_by_user: create(:user))
    page.current_window.resize_to(375, 900)
    login
    visit new_oshi_path
    expect(page).to have_css("#oshi-search-results[data-oshi-search-state='initial'][data-oshi-search-count='0']")
    expect(page).to have_text(I18n.t("ui.oshi.catalog.empty"))
    expect(page).not_to have_text(I18n.t("ui.oshi.no_results"))
    expect(page).to have_field("oshi_name", with: "")
    capture_cards(375, "empty-catalog")
    search("まだない推し")
    expect(page).to have_css("#oshi-search-results[data-oshi-search-state='empty']")
    expect(page).to have_field("oshi_name", with: "まだない推し")
    click_link "既存の推しを検索し直す"
    search("")
    expect(page).to have_css("#oshi-search-results[data-oshi-search-state='initial']")
    expect(page).to have_field("oshi_name", with: "まだない推し")
  end

  it "submits a selected catalog radio with JavaScript disabled at375px" do
    setup_catalog
    page.current_window.resize_to(375, 900)
    login
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    begin
      visit new_oshi_path
      expect_initial_cards
      within("#oshi-search-results") { choose @candidate.name, exact: false }
      capture_cards(375, "no-js", no_js: true)
      within("form[action='#{user_oshis_path}']") { click_button "選んだ推しを追加" }
      expect(page).to have_current_path(oshis_path)
      expect(page).to have_css("main h1", exact_text: "推し一覧")
      expect(user.user_oshis.find_by!(oshi: @candidate).started_period).to be_nil
    ensure
      page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
    end
  end

  it "rechecks the actor before restoring cached cards in an old activity panel" do
    setup_catalog
    open_activity("new", 375)
    search("未登録の検索語")
    expect(page).to have_css("#oshi-search-results[data-oshi-search-state='empty']")
    other = create(:user)
    other_window = open_new_window
    within_window(other_window) do
      visit root_path
      click_button "ログアウト"
      expect(page).to have_current_path(new_user_session_path)
      expect(page).to have_field("user_email")
      login(other)
    end
    search("")
    expect(page).to have_text(I18n.t("ui.activity_panel.context_error"))
    expect(page).to have_no_css("#oshi-search-results [data-catalog-oshi-id]")
    expect(page).to have_css("#oshi-search-results[data-oshi-search-state='empty']")
    expect_activity_preserved
    expect(other.user_oshis).to be_empty
    capture_cards(375, "actor-rejected")
  ensure
    other_window&.close
  end

  it "reveals complete long names and affiliations by keyboard without selecting or saving" do
    long_name = "03_" + ("LongName" * 25)
    affiliation = "作品" + ("所属" * 70)
    candidate = create(:oshi, :approved, name: long_name, affiliation: affiliation)
    page.current_window.resize_to(375, 900)
    login
    visit new_oshi_path
    expect(page).to have_css(".oshi-catalog-card", count: 1)
    counts = [ Oshi.count, UserOshi.count ]
    within("[data-catalog-oshi-id='#{candidate.id}']") do
      radio = find("input[type=radio]")
      radio.send_keys(:tab)
      expect(page).to have_css("summary:focus")
      find("summary").send_keys(:enter)
      expect(page).to have_css("details[open]")
      expect(page).to have_css("dd", exact_text: long_name)
      expect(page).to have_css("dd", exact_text: affiliation)
      expect(page).to have_no_css("input:checked")
      find("summary").send_keys(:space)
      expect(page).to have_no_css("details[open]")
      choose long_name, exact: false
      expect(page).to have_checked_field(long_name, exact: false)
    end
    expect([ Oshi.count, UserOshi.count ]).to eq(counts)
  end
end
