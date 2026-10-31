require "rails_helper"
require "vips"
require "digest"
require "tmpdir"
require "json"
require "base64"
require "active_storage/service/disk_service"
require "active_support/testing/time_helpers"
require_relative "../support/started_period_picker"

RSpec.describe "Inline oshi registration during activity input", type: :system do
  include StartedPeriodPicker
  include ActiveSupport::Testing::TimeHelpers
  include_context "emotion master data"

  let(:user) { create(:user) }
  let(:personal) { create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "保持する推し")) }
  let(:candidate) { create(:oshi, :approved, name: "追加する既存候補") }

  around do |example|
    Dir.mktmpdir("h04-inline-", Rails.root.join("tmp")) do |directory|
      @directory = Pathname.new(directory)
      example.run
    end
  end

  before do
    service = ActiveStorage::Service::DiskService.new(root: @directory.join("storage"))
    service.name = "test"
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)
    allow(ActiveStorage::Blob).to receive(:services).and_return({ "test" => service })
    @large = image_file("activity-blue.png", 3000, 2000, [ 24, 90, 210 ])
    @small = image_file("activity-green.png", 80, 60, [ 30, 160, 80 ])
    @saved = image_file("saved-red.png", 64, 48, [ 210, 48, 45 ])
  end

  def image_file(name, width, height, color)
    path = @directory.join(name)
    Vips::Image.black(width, height, bands: 3).new_from_image(color).copy(interpretation: :srgb).write_to_file(path.to_s, compression: 9, strip: true)
    path
  end

  def login(account = user)
    visit new_user_session_path
    fill_in "user_email", with: account.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def open_activity(mode = "new", width: 1280, photos: true)
    personal
    @activity = nil
    if mode == "edit"
      @activity = build(:activity, user: user, oshis_count: 0, title: "保存済みの活動")
      Activities::Save.call(activity: @activity, oshi_ids: [ personal.oshi_id ])
      @activity.images.attach(io: File.open(@saved, "rb"), filename: "saved-red.png", content_type: "image/png")
    end
    page.current_window.resize_to(width, 900)
    login
    visit(mode == "new" ? new_activity_path : edit_activity_path(@activity))
    fill_in "activity_title", with: "残す活動タイトル"
    fill_in "activity_place", with: "残す場所"
    fill_in "activity_memo", with: "残すメモ\n2行目"
    fill_in "activity_amount", with: "0"
    fill_in "活動日（必須）", with: Date.new(2026, 10, 2)
    select "ライブ・イベント", from: "カテゴリ（必須）"
    check personal.oshi.name, allow_label_click: true
    check "感動", allow_label_click: true
    if photos
      attach_file "activity_images", [ @large, @small ]
      expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
      expect(page).to have_css("[data-image-upload-target='preview'] img", count: 2)
    end
    @fields = fields
    @files = file_info
    page.execute_script(<<~JS)
      const input=document.querySelector("#activity_images");
      window.originalActivityForm=input.form;
      window.originalActivityInput=input;
      window.originalActivityFiles=input.files;
      window.originalImageController=window.Stimulus.getControllerForElementAndIdentifier(input.closest("[data-controller~='image-upload']"),"image-upload");
      window.originalPreviewURLs=[...document.querySelectorAll("[data-image-upload-target='previewImages'] img")].map(img=>img.src);
    JS
    @activity_count = Activity.count
    @image_counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
  end

  def fields
    page.evaluate_script(<<~JS)
      (() => {
        const result={};
        for(const id of ["activity_title","activity_place","activity_memo","activity_amount","activity_occurred_on","activity_activity_type"])result[id]=document.getElementById(id).value;
        result.emotions=[...document.querySelectorAll("input[name='activity[emotion_ids][]']:checked")].map(input=>input.value);
        result.lock_version=document.querySelector("input[name='activity[lock_version]']")?.value || null;
        return result;
      })()
    JS
  end

  def file_info
    page.evaluate_async_script(<<~JS)
      const done=arguments[0];
      Promise.all([...document.querySelector("#activity_images").files].map(async file=>{
        const digest=await crypto.subtle.digest("SHA-256",await file.arrayBuffer());
        return {name:file.name,bytes:file.size,type:file.type,sha256:[...new Uint8Array(digest)].map(byte=>byte.toString(16).padStart(2,"0")).join("")};
      })).then(done);
    JS
  end

  def expect_preserved(same_dom: true)
    expect(fields).to eq(@fields)
    expect(file_info).to eq(@files)
    if same_dom
      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => {
          const input=document.querySelector("#activity_images");
          return input===window.originalActivityInput && input.form===window.originalActivityForm &&
            input.files===window.originalActivityFiles &&
            window.Stimulus.getControllerForElementAndIdentifier(input.closest("[data-controller~='image-upload']"),"image-upload")===window.originalImageController &&
            JSON.stringify([...document.querySelectorAll("[data-image-upload-target='previewImages'] img")].map(img=>img.src))===JSON.stringify(window.originalPreviewURLs);
        })()
      JS
    end
    expect(Activity.count).to eq(@activity_count)
    expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(@image_counts)
  end

  def open_panel
    click_button "推しを追加", exact: true
    expect(page).to have_css("#activity-oshi-panel:not([hidden]) input[type='search']")
    expect(page).to have_no_css("#activity-oshi-panel input[type='file']", visible: :all)
  end

  def search(query, pointer: false)
    within("#activity-oshi-panel") do
      fill_in "推しを検索", with: query
      if pointer
        button = find_button("検索", exact: true)
        page.driver.browser.action.move_to(button.native).click.perform
      else
        click_button "検索", exact: true
      end
    end
  end

  def add_existing(record = candidate)
    search(record.name)
    within("#oshi-existing form[action='#{user_oshis_path}']") do
      choose record.name, exact: false
      find("input[type='submit']").click
    end
    expect(page).to have_checked_field(record.name, type: "checkbox", visible: :all)
  end

  def register_new(name, affiliation: "合成作品", period: nil)
    search(name)
    expect(page).to have_field("推し名（必須）", with: name)
    within("#oshi-registration") do
      select "声優", from: "種別（必須）"
      fill_in "所属・作品", with: affiliation
      select_started_period(period) if period
      find("input[type='submit']").click
    end
  end

  def status_text
    find("[data-activity-oshi-panel-target='status']").text
  end

  def wait_status(key)
    expect(page).to have_css("[data-activity-oshi-panel-target='status']", text: I18n.t("ui.activity_panel.#{key}"), exact_text: true)
  end

  def save_activity(mode)
    within("[data-activity-oshi-panel-target='activityForm']") { click_button(mode == "new" ? "記録する" : "更新する") }
    expect(page).to have_css("[role='status']", text: mode == "new" ? "活動記録を登録しました。" : "活動記録を更新しました。")
  end

  [ 375, 1280 ].each do |width|
    %w[new edit].each do |mode|
      it "adds existing and new oshis without replacing #{mode} inputs at #{width}px", :h04_capture do
        open_activity(mode, width: width)
        existing = candidate
        open_panel
        expect(page).to have_text(I18n.t("ui.activity_panel.separate_save"))
        add_existing(existing)
        expect_preserved
        name = "パネル新規#{mode}#{width}"
        register_new(name, period: "2020/05")
        expect(page).to have_checked_field(name, type: "checkbox", visible: :all)
        created = user.user_oshis.joins(:oshi).find_by!(oshis: { name: name })
        expect(created.oshi).to be_pending
        expect(created.started_period).to eq("2020/05")
        expect_preserved
        expect(page).to have_checked_field(personal.oshi.name, type: "checkbox", visible: :all)
        capture(mode, width)
        click_button I18n.t("ui.activity_panel.close")
        expect_preserved
        open_panel
        expect_preserved
        click_button I18n.t("ui.activity_panel.close")
        save_activity(mode)
        saved = mode == "new" ? user.activities.find_by!(title: "残す活動タイトル") : @activity.reload
        expect(saved.oshi_ids).to match_array([ personal.oshi_id, existing.id, created.oshi_id ])
        expect(saved.amount).to eq(0)
        expect(saved.images.count).to eq(mode == "new" ? 2 : 3)
      end
    end
  end

  it "selects an already registered oshi without POST and preserves a later manual choice" do
    open_activity
    open_panel
    search(personal.oshi.name)
    within("#oshi-existing form[action='#{user_oshis_path}']") { choose personal.oshi.name, exact: false }
    page.execute_script(<<~JS)
      const original=window.fetch;
      window.fetch=(url,options)=>{
        if((options?.method || "GET")==="GET" && new URL(url,location.href).pathname===new URL(document.querySelector("[data-activity-oshi-panel-owned-url-value]").dataset.activityOshiPanelOwnedUrlValue,location.href).pathname){
          return new Promise(resolve=>{window.releaseOwned=()=>original(url,options).then(resolve)});
        }
        return original(url,options);
      };
    JS
    before = UserOshi.count
    within("#oshi-existing form[action='#{user_oshis_path}']") { find("input[type='submit']").click }
    expect(page).to have_css("[data-activity-oshi-panel-target='panel'][aria-busy='true']")
    uncheck personal.oshi.name, allow_label_click: true
    page.execute_script("window.releaseOwned()")
    wait_status("kept")
    expect(page).to have_unchecked_field(personal.oshi.name, type: "checkbox", visible: :all)
    expect(UserOshi.count).to eq(before)
    expect_preserved
  end

  it "keeps activity and registration input after a period validation error" do
    open_activity
    open_panel
    search("期間エラーから戻る")
    within("#oshi-registration") do
      select "声優", from: "種別（必須）"
      page.execute_script("document.querySelector('#new_user_oshi_started_period').value='2020/13'")
      find("input[type='submit']").click
    end
    wait_status("validation")
    expect(page).to have_css("[data-activity-oshi-panel-target='errors'] li", minimum: 1)
    expect(page).to have_field("推し名（必須）", with: "期間エラーから戻る")
    expect(user.user_oshis.count).to eq(1)
    expect_preserved
  end

  it "keeps UX01 name protection and only closes Escape outside IME composition" do
    open_activity
    open_panel
    search("検索ゼロの名前")
    expect(page).to have_field("推し名（必須）", with: "検索ゼロの名前")
    fill_in "推し名（必須）", with: "手で残す名前"
    search("別の検索ゼロ")
    expect(page).to have_field("推し名（必須）", with: "手で残す名前")
    page.execute_script("document.querySelector('#q').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',isComposing:true,bubbles:true}))")
    expect(page).to have_css("#activity-oshi-panel:not([hidden])")
    find("#q").send_keys(:escape)
    expect(page).to have_css("#activity-oshi-panel[hidden]", visible: :all)
    expect(page.evaluate_script("document.activeElement.textContent")).to eq(I18n.t("ui.activity_panel.open"))
    expect_preserved
  end

  [ true, false ].each do |image_first|
    it "keeps independent submit guards when image_first=#{image_first}" do
      open_activity(photos: false)
      existing = candidate
      open_panel
      search(existing.name)
      within("#oshi-existing form[action='#{user_oshis_path}']") { choose existing.name, exact: false }
      page.execute_script(<<~JS)
        const bitmap=createImageBitmap;let first=true;
        window.createImageBitmap=(...args)=>{
          if(!first)return bitmap(...args);first=false;
          return new Promise((resolve,reject)=>{window.releaseImage=()=>bitmap(...args).then(resolve,reject)});
        };
        const original=fetch;
        window.fetch=(url,options)=>{
          if(options?.method==="POST" && new URL(url,location.href).pathname.endsWith("/user_oshis")){
            return new Promise((resolve,reject)=>{window.releasePost=()=>original(url,options).then(resolve,reject)});
          }
          return original(url,options);
        };
      JS
      attach_file "activity_images", @large
      expect(page).to have_button("記録する", disabled: true)
      within("#oshi-existing form[action='#{user_oshis_path}']") { find("input[type='submit']").click }
      expect(page).to have_css("[data-activity-oshi-panel-target='panel'][aria-busy='true']")
      expect(page.evaluate_async_script("const done=arguments[0],end=Date.now()+3000;function poll(){if(window.releasePost && window.releaseImage)return done(true);if(Date.now()>end)return done(false);setTimeout(poll,10)}poll()")).to be(true)
      page.execute_script("document.querySelector('[data-activity-oshi-panel-target=activityForm]').submit()")
      wait_status("posting")
      expect(Activity.count).to eq(0)
      if image_first
        page.execute_script("window.releaseImage()")
        expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
        expect(page).to have_button("記録する", disabled: false)
        page.execute_script("document.querySelector('[data-activity-oshi-panel-target=activityForm]').requestSubmit()")
        wait_status("posting")
        expect(Activity.count).to eq(0)
        page.execute_script("window.releasePost()")
        expect(page).to have_checked_field(existing.name, type: "checkbox", visible: :all)
      else
        page.execute_script("window.releasePost()")
        expect(page).to have_checked_field(existing.name, type: "checkbox", visible: :all)
        expect(page).to have_button("記録する", disabled: true)
        page.execute_script("document.querySelector('[data-activity-oshi-panel-target=activityForm]').requestSubmit()")
        expect(Activity.count).to eq(0)
        page.execute_script("window.releaseImage()")
        expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
      end
      expect(page).to have_button("記録する", disabled: false)
      expect(fields).to eq(@fields)
      expect(page.evaluate_script("document.querySelector('#activity_images')===window.originalActivityInput")).to be(true)
      click_button I18n.t("ui.activity_panel.close")
      save_activity("new")
    end
  end

  it "does not resend a response-lost registration or infer success from its name" do
    open_activity
    open_panel
    page.execute_script(<<~JS)
      const original=fetch;window.newPosts=0;
      window.fetch=async(url,options)=>{
        const response=await original(url,options);
        if(options?.method==="POST" && new URL(url,location.href).pathname.endsWith("/oshis")){
          window.newPosts++;throw new TypeError("Artificial lost response");
        }
        return response;
      };
    JS
    register_new("結果不明の同名", affiliation: "確認する作品")
    wait_status("unknown")
    expect(page).to have_no_field("結果不明の同名", type: "checkbox", visible: :all)
    expect(user.user_oshis.count).to eq(2)
    page.execute_script("document.querySelector('#oshi-registration form').requestSubmit()")
    expect(page.evaluate_script("window.newPosts")).to eq(1)
    click_button I18n.t("ui.activity_panel.confirm")
    expect(page).to have_text(I18n.t("ui.activity_panel.review_help"))
    within("[data-activity-oshi-panel-target='registeredResults'] p", text: "結果不明の同名／声優／確認する作品") do
      click_button I18n.t("ui.activity_panel.select")
    end
    expect(page).to have_checked_field("結果不明の同名", type: "checkbox", visible: :all)
    expect(page.evaluate_script("window.newPosts")).to eq(1)
    expect_preserved
  end

  it "ignores a late completion after close and continue and does not repost on Turbo back" do
    open_activity
    open_panel
    page.execute_script(<<~JS)
      const original=fetch;window.newPosts=0;
      window.fetch=async(url,options)=>{
        const response=await original(url,options);
        if(options?.method==="POST" && new URL(url,location.href).pathname.endsWith("/oshis")){
          window.newPosts++;
          return new Promise(resolve=>{window.releaseLate=()=>resolve(response)});
        }
        return response;
      };
    JS
    register_new("閉じた後の結果")
    expect(page).to have_css("[data-activity-oshi-panel-target='panel'][aria-busy='true']")
    expect(page.evaluate_async_script("const done=arguments[0],end=Date.now()+3000;function poll(){if(window.releaseLate)return done(true);if(Date.now()>end)return done(false);setTimeout(poll,10)}poll()")).to be(true)
    click_button I18n.t("ui.activity_panel.close")
    wait_status("unknown")
    click_button I18n.t("ui.activity_panel.continue_without")
    wait_status("continued")
    page.execute_script("window.releaseLate()")
    expect(page).to have_no_field("閉じた後の結果", type: "checkbox", visible: :all)
    expect_preserved
    click_link "活動記録一覧へ戻る"
    expect(page).to have_current_path(activities_path)
    page.go_back
    expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
    expect_preserved(same_dom: false)
    expect(page.evaluate_script("window.newPosts")).to eq(1)
    open_panel
    expect(page).to have_field("推し名（必須）", with: "閉じた後の結果")
    within("#oshi-registration") { find("input[type='submit']").click }
    wait_status("unknown")
    expect(page.evaluate_script("window.newPosts")).to eq(1)
  end

  %w[new edit].each do |mode|
    it "stops old #{mode} activity and panel requests after another account signs in" do
      open_activity(mode)
      open_panel
      other = create(:user)
      original = current_window
      second = open_new_window
      within_window(second) do
        visit root_path
        click_button "ログアウト"
        fill_in "user_email", with: other.email
        fill_in "user_password", with: "password123"
        click_button "ログイン"
        expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
      end
      switch_to_window(original)
      page.execute_script("document.querySelector('[data-activity-oshi-panel-target=activityForm]').submit()")
      wait_status("context_error")
      expect_preserved
      expect(other.activities).to be_empty
      expect(other.user_oshis).to be_empty
      within("#oshi-registration") do
        fill_in "推し名（必須）", with: "別人へ保存しない"
        select "声優", from: "種別（必須）"
        find("input[type='submit']").click
      end
      expect(other.user_oshis).to be_empty
      expect_preserved
      second.close
    end
  end

  it "keeps unsaved fields and photos in the page when the context expires" do
    open_activity
    travel 2.hours + 1.second do
      page.execute_script("document.querySelector('[data-activity-oshi-panel-target=activityForm]').requestSubmit()")
      wait_status("context_error")
      expect_preserved
    end
  end


  it "restores an uncertain POST after whole-controller reconnect without replaying it" do
    open_activity
    open_panel
    page.execute_script(<<~JS)
      const original=fetch;window.pendingPosts=0;
      window.fetch=async(url,options)=>{
        const response=await original(url,options);
        if(options?.method==="POST" && new URL(url,location.href).pathname.endsWith("/oshis")){
          window.pendingPosts++;
          return new Promise(resolve=>{window.releaseReconnect=()=>resolve(response)});
        }
        return response;
      };
    JS
    register_new("再接続する登録")
    expect(page.evaluate_async_script("const done=arguments[0],end=Date.now()+3000;function poll(){if(window.releaseReconnect)return done(true);if(Date.now()>end)return done(false);setTimeout(poll,10)}poll()")).to be(true)
    page.execute_script(<<~JS)
      window.savedRoot=document.querySelector("[data-controller~='activity-oshi-panel']");
      window.rootAnchor=document.createComment("controller reconnect");
      window.savedRoot.before(window.rootAnchor);
      window.savedRoot.remove();
    JS
    page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
    page.execute_script("window.rootAnchor.replaceWith(window.savedRoot)")
    page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
    wait_status("unknown")
    expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
    expect_preserved(same_dom: false)
    expect(page.evaluate_script("document.querySelector('#activity_images')===window.originalActivityInput")).to be(true)
    page.evaluate_async_script("const done=arguments[0];window.releaseReconnect();setTimeout(()=>done(true),0)")
    expect(page).to have_no_field("再接続する登録", type: "checkbox", visible: :all)
    within("#oshi-registration") { find("input[type='submit']").click }
    wait_status("unknown")
    expect(page.evaluate_script("window.pendingPosts")).to eq(1)
    click_button I18n.t("ui.activity_panel.continue_without")
    wait_status("continued")
  end

  it "treats a POST timeout as unknown and lets the user continue without resending" do
    open_activity
    open_panel
    search("時間切れの登録")
    within("#oshi-registration") { select "声優", from: "種別（必須）" }
    page.execute_script(<<~JS)
      window.timeoutFetch=fetch;window.timeoutTimer=setTimeout;window.timeoutPosts=0;
      window.setTimeout=(callback,delay,...args)=>window.timeoutTimer(callback,delay===15000?500:delay,...args);
      window.fetch=(url,options)=>{
        if(options?.method==="POST" && new URL(url,location.href).pathname.endsWith("/oshis")){
          window.timeoutPosts++;
          return new Promise((_resolve,reject)=>options.signal.addEventListener("abort",()=>reject(new DOMException("Artificial timeout","AbortError")),{once:true}));
        }
        return window.timeoutFetch(url,options);
      };
    JS
    within("#oshi-registration") { find("input[type='submit']").click }
    wait_status("unknown")
    expect(user.user_oshis.count).to eq(1)
    expect(page).to have_css("[data-activity-oshi-panel-target='panel'][aria-busy='false']")
    page.execute_script("document.querySelector('#oshi-registration form').requestSubmit()")
    expect(page.evaluate_script("window.timeoutPosts")).to eq(1)
    click_button I18n.t("ui.activity_panel.confirm")
    expect(page).to have_text(I18n.t("ui.activity_panel.review_help"))
    expect(page).to have_no_field("時間切れの登録", type: "checkbox", visible: :all)
    expect_preserved
    click_button I18n.t("ui.activity_panel.continue_without")
    wait_status("continued")
    page.execute_script("window.fetch=window.timeoutFetch;window.setTimeout=window.timeoutTimer")
    click_button I18n.t("ui.activity_panel.close")
    save_activity("new")
  end


  after do
    @delivery_tab&.close
  end

  def prepare_delivery_tab
    @delivery_tab = open_new_window
    within_window(@delivery_tab) do
      visit root_path
      page.execute_script("window.name='h04-delivery-auth'")
    end
    page.execute_script("window.deliveryAuthTab=window.open('', 'h04-delivery-auth')")
    page.driver.browser.execute_cdp("Page.bringToFront")
    expect(page.evaluate_script("document.visibilityState")).to eq("visible")
  end

  def change_delivery_actor(account = nil)
    result = page.evaluate_async_script(<<~JS, account&.email)
      const done=arguments[arguments.length-1],email=arguments[0],tab=window.deliveryAuthTab;
      (async()=>{
        const csrf=tab.document.querySelector('meta[name="csrf-token"]')?.content;
        let response=await tab.fetch('/users/sign_out',{method:'DELETE',credentials:'same-origin',headers:{'X-CSRF-Token':csrf || ''}});
        let html=await response.text();
        if(email){
          const token=new DOMParser().parseFromString(html,'text/html').querySelector('meta[name="csrf-token"]')?.content;
          response=await tab.fetch('/users/sign_in',{method:'POST',credentials:'same-origin',
            headers:{'Content-Type':'application/x-www-form-urlencoded','X-CSRF-Token':token || ''},
            body:new URLSearchParams({'user[email]':email,'user[password]':'password123'})});
          html=await response.text();
        }
        done({status:response.status,authenticated:html.includes('>ホーム</h1>')});
      })().catch(error=>done({error:error.name}));
    JS
    expect(result).to eq({ "status" => account.nil? ? 204 : 200, "authenticated" => !account.nil? })
  end

  def hold_delivery(kind = "html")
    page.execute_script(<<~JS, kind)
      window.deliveryFetch=window.fetch;window.deliveryHeld=false;window.deliverySeenHTML=false;
      window.deliveryStatus=null;window.releaseDelivery=null;
      document.documentElement.dataset.h04DeliveryHeld="false";
      window.deliveryProbe={kind:arguments[0],stage:"armed",path:null,status:null,
        htmlRequested:false,htmlSeen:false,bodyRead:false,error:null};
      const root=document.querySelector('[data-controller~="activity-oshi-panel"]');
      const htmlPath=new URL(root.dataset.activityOshiPanelRegistrationUrlValue,location.href).pathname;
      const ownedPath=new URL(root.dataset.activityOshiPanelOwnedUrlValue,location.href).pathname;
      const kind=arguments[0];
      window.fetch=async(url,options)=>{
        const target=new URL(url,location.href),path=target.pathname;
        const htmlRequest=path===htmlPath && target.searchParams.get('suggest')!=='1';
        if(htmlRequest)window.deliveryProbe.htmlRequested=true;
        const expected=kind==='html'?htmlRequest:window.deliverySeenHTML && path===ownedPath;
        if(!window.deliveryHeld && expected)Object.assign(window.deliveryProbe,{stage:"request_started",path});
        try{
          const response=await window.deliveryFetch(url,options);
          // Observe the original panel/confirmed-search boundary, independently of input candidates.
          const html=htmlRequest && response.headers.get('Content-Type')?.includes('text/html');
          if(html){
            window.deliverySeenHTML=true;window.deliveryProbe.htmlSeen=true;
            if(kind==='check' && window.deliveryProbe.stage==='armed')window.deliveryProbe.stage="awaiting_check";
          }
          if(!window.deliveryHeld && ((kind==='html' && html) ||
              (kind==='check' && window.deliverySeenHTML && path===ownedPath))){
            Object.assign(window.deliveryProbe,{stage:"body_pending",path,status:response.status});
            await response.clone().text();
            window.deliveryHeld=true;window.deliveryStatus=response.status;
            Object.assign(window.deliveryProbe,{stage:"held",bodyRead:true});
            document.documentElement.dataset.h04DeliveryHeld="true";
            return new Promise(resolve=>{window.releaseDelivery=()=>resolve(response)});
          }
          return response;
        }catch(error){
          if(expected || htmlRequest)Object.assign(window.deliveryProbe,{stage:"error",error:error.name});
          throw error;
        }
      };
    JS
  end

  def wait_delivery
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(page).to have_css("html[data-h04-delivery-held='true']", wait: 4)
    expect(page.evaluate_script(<<~JS)).to eq("held" => true, "body_read" => true, "status" => 200)
      ({held:window.deliveryHeld===true,body_read:window.deliveryProbe?.bodyRead===true,status:window.deliveryStatus})
    JS
  rescue RSpec::Expectations::ExpectationNotMetError, Selenium::WebDriver::Error::WebDriverError => error
    warn JSON.generate(delivery_wait_error: error.class.name,
      host_elapsed_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
      snapshot: delivery_diagnostics)
    raise
  end

  def delivery_diagnostics
    page.evaluate_script(<<~JS)
      (() => {
        const probe=window.deliveryProbe || {},root=document.querySelector('[data-controller~="activity-oshi-panel"]');
        return {kind:probe.kind || null,stage:probe.stage || null,path:probe.path || null,
          status:probe.status ?? null,html_requested:probe.htmlRequested===true,html_received:probe.htmlSeen===true,
          body_read:probe.bodyRead===true,held:window.deliveryHeld===true,error:probe.error || null,
          visibility:document.visibilityState,root_connected:!!root?.isConnected,
          search_exists:!!root?.querySelector("input[name='q']"),
          auth_window_exists:!!window.deliveryAuthTab,auth_window_closed:window.deliveryAuthTab?.closed ?? null,
          release_ready:typeof window.releaseDelivery==="function"};
      })()
    JS
  rescue Selenium::WebDriver::Error::WebDriverError => error
    { snapshot_error: error.class.name }
  end

  def remember_delivery_state
    page.execute_script(<<~JS)
      const component=document.querySelector('[data-controller~="oshi-registration"]');
      window.deliveryComponent=component;
      window.deliveryResults=component?.querySelector('#oshi-search-results')?.innerHTML || null;
      window.deliveryName=component?.querySelector('input[name="oshi[name]"]')?.value || null;
      window.deliveryChoices=[...document.querySelectorAll('input[name="activity[oshi_ids][]"]')].map(x=>[x.value,x.checked]);
      window.deliveryFocus=document.activeElement;
    JS
  end

  def release_delivery
    page.execute_script(<<~JS)
      if(!window.deliveryHeld || typeof window.releaseDelivery!=="function")throw new Error("Delivery response is not held");
      window.deliveryProbe.stage="released";
      window.releaseDelivery();
    JS
  end

  def expect_delivery_unchanged
    expect(page.evaluate_script(<<~JS)).to be(true)
      (() => {
        const component=document.querySelector('[data-controller~="oshi-registration"]');
        return component===window.deliveryComponent &&
          (component?.querySelector('#oshi-search-results')?.innerHTML || null)===window.deliveryResults &&
          (component?.querySelector('input[name="oshi[name]"]')?.value || null)===window.deliveryName &&
          JSON.stringify([...document.querySelectorAll('input[name="activity[oshi_ids][]"]')].map(x=>[x.value,x.checked]))===JSON.stringify(window.deliveryChoices) &&
          document.activeElement===window.deliveryFocus;
      })()
    JS
    expect_preserved
  end

  %w[panel search].each_with_index do |boundary, index|
    %w[switch logout same].each do |actor|
      it "checks received #{boundary} HTML after #{actor} before applying it", :h04_delivery, h04_delivery_red: actor == "switch" do
        private_oshi = create(:oshi, status: :pending, created_by_user: user, name: "A専用の保留候補")
        open_activity(index.zero? ? "new" : "edit", width: index.zero? ? 375 : 1280)
        prepare_delivery_tab
        if boundary == "search"
          open_panel
          search("消さずに残す自動名")
          expect(page).to have_field("推し名（必須）", with: "消さずに残す自動名")
        end
        hold_delivery
        boundary == "panel" ? click_button("推しを追加", exact: true) : search(private_oshi.name)
        wait_delivery
        remember_delivery_state
        change_delivery_actor(actor == "switch" ? create(:user) : nil) unless actor == "same"
        release_delivery
        if actor == "same"
          if boundary == "panel"
            expect(page).to have_css("#activity-oshi-panel input[type='search']")
          else
            expect(page).to have_field("推し名（必須）", with: "")
            expect(page).to have_css("#oshi-search-results", text: private_oshi.name)
          end
          register_new("配送後も本人の登録#{boundary}")
          expect(page).to have_checked_field("配送後も本人の登録#{boundary}", type: "checkbox", visible: :all)
          expect_preserved
        else
          wait_status("context_error")
          expect(page).to have_link(I18n.t("ui.activity_panel.restart"))
          expect_delivery_unchanged
          expect(page).to have_no_text(private_oshi.name) if boundary == "panel"
        end
      end
    end
  end

  %w[query name selection close reconnect].each_with_index do |intent, index|
    it "discards search HTML when #{intent} changes during the final continuity check", :h04_delivery do
      existing = candidate
      unchanged_selection = create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "変更しない別のチェック")) if intent == "selection"
      open_activity(width: index.even? ? 375 : 1280)
      check unchanged_selection.oshi.name, allow_label_click: true if unchanged_selection
      open_panel
      search("確認待ちでも残す自動名")
      expect(page).to have_field("推し名（必須）", with: "確認待ちでも残す自動名")
      hold_delivery("check")
      search(existing.name, pointer: true)
      wait_delivery
      case intent
      when "query"
        fill_in "推しを検索", with: "新しい検索意図"
        expect(page).to have_css("#oshi-search-results[data-oshi-search-mode='suggestions'][data-oshi-search-query='新しい検索意図']", visible: :all)
      when "name"
        page.execute_script("const x=document.querySelector('input[name=\"oshi[name]\"]');x.value='本人が書いた名前';x.dispatchEvent(new Event('input',{bubbles:true}))")
      when "selection"
        selection_target = find("input[type='checkbox'][name='activity[oshi_ids][]'][value='#{personal.oshi_id}']", visible: :all)
        expect(selection_target[:id]).to be_present
        expect(selection_target).to be_checked
        expect(page).to have_checked_field(unchanged_selection.oshi.name, type: "checkbox", visible: :all)
        selection_expected = delivery_checkbox_state
        expect(selection_expected.fetch(selection_target[:id])).to be(true)
        selection_expected[selection_target[:id]] = false
        page.execute_script(<<~JS, selection_target[:id])
          const input=document.getElementById(arguments[0]);
          if(!input?.matches("input[type='checkbox'][name='activity[oshi_ids][]']") || !input.checked)
            throw new Error("Expected the checked personal oshi checkbox");
          input.checked=false;input.dispatchEvent(new Event("change",{bubbles:true}));
        JS
        expect(page).to have_unchecked_field(selection_target[:id], type: "checkbox", visible: :all)
        expect(delivery_checkbox_state).to eq(selection_expected)
      when "close"
        click_button I18n.t("ui.activity_panel.close")
      when "reconnect"
        page.execute_script("window.deliveryRoot=document.querySelector('[data-controller~=\"activity-oshi-panel\"]');window.deliveryAnchor=document.createComment('delivery reconnect');window.deliveryRoot.before(window.deliveryAnchor);window.deliveryRoot.remove()")
        page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
        page.execute_script("window.deliveryAnchor.replaceWith(window.deliveryRoot)")
        page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
      end
      remember_delivery_state
      release_delivery
      expect(page).to have_css("#oshi-search-results:not([aria-busy])", visible: :all)
      expect_delivery_unchanged unless intent == "reconnect"
      if intent == "selection"
        expect(delivery_checkbox_state).to eq(selection_expected)
        expect(page).to have_unchecked_field(selection_target[:id], type: "checkbox", visible: :all)
        expect(page).to have_checked_field(unchanged_selection.oshi.name, type: "checkbox", visible: :all)
      end
      if intent == "reconnect"
        expect(fields).to eq(@fields)
        expect(file_info).to eq(@files)
        expect(page).to have_field("推し名（必須）", with: "確認待ちでも残す自動名", visible: :all)
        expect(page.evaluate_script("document.querySelector('#oshi-search-results').innerHTML===window.deliveryResults")).to be(true)
      end
    end
  end

  def delivery_checkbox_state
    page.evaluate_script(<<~JS)
      Object.fromEntries([...document.querySelectorAll("input[type='checkbox'][name='activity[oshi_ids][]']")]
        .map(input=>[input.id,input.checked]))
    JS
  end

  def capture(mode, width)
    directory = Rails.root.join("tmp/h04-inline-oshi-ui", ENV.fetch("H04_CAPTURE_LABEL", "local"))
    FileUtils.mkdir_p(directory)
    input = find_field("推し名（必須）")
    page.execute_script("arguments[0].scrollIntoView({block:'center',behavior:'instant'})", input)
    record = { mode: mode, width: width, fields: fields, files: file_info, activity_count_before_save: Activity.count,
      same_DOM_and_image_instance_asserted: true, test_scrolled_for_inspection: true }
    %w[panel photos].each do |part|
      if part == "photos"
        page.execute_script("document.querySelector('[data-image-upload-target=preview]').scrollIntoView({block:'center',behavior:'instant'})")
      end
      expect(page.evaluate_script("document.documentElement.scrollWidth<=innerWidth")).to be(true)
      screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
      path = directory.join("#{mode}-#{width}-#{part}.png")
      File.binwrite(path, Base64.strict_decode64(screenshot.fetch("data")))
      record[part] = { path: path.to_s, sha256: Digest::SHA256.file(path).hexdigest }
    end
    File.write(directory.join("#{mode}-#{width}.json"), JSON.pretty_generate(record))
  end
end
