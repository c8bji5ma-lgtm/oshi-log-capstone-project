require "rails_helper"
require "json"
require "base64"
require_relative "../support/started_period_picker"

RSpec.describe "Input suggestions without automatic registration", type: :system do
  include StartedPeriodPicker
  include_context "emotion master data"

  let(:user) { create(:user) }

  def setup_candidates
    @personal = create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "予測候補0追加済み"))
    @candidate = create(:oshi, :approved, name: "予測候補A", affiliation: "合成作品")
    @second = create(:oshi, :approved, name: "予測候補B")
    @long = create(:oshi, :approved, name: "予測候補C" + ("LongName" * 23))
    @pending = create(:oshi, :pending, name: "予測候補D本人申請", created_by_user: user)
    @private = create(:oshi, :pending, name: "予測候補の非公開", created_by_user: create(:user))
    @common = create(:oshi_common_image, oshi: @candidate, attribution_text: "合成候補画像の帰属")
    create(:oshi_common_image, oshi: @second, active: false, attribution_text: "表示しない候補画像")
  end

  def login(account = user)
    visit new_user_session_path
    fill_in "user_email", with: account.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", exact_text: "ホーム")
  end

  def open_registration(width = 375)
    page.current_window.resize_to(width, 900)
    login
    visit new_oshi_path
    expect(page).to have_css("input[name=q][role=combobox][aria-expanded=false][aria-controls=oshi-suggestions]")
  end

  def query
    find("input[name=q]")
  end

  def options
    page.all("#oshi-suggestions:not([hidden]) [role=option]")
  end

  def type_query(value)
    fill_in "推しを検索", with: value
  end

  def confirm_search(value)
    type_query(value)
    click_button "検索", exact: true
  end

  def wait_suggestions(value = "予測候補")
    expect(page).to have_css("#oshi-search-results[data-oshi-search-mode='suggestions'][data-oshi-search-query='#{value}']", visible: :all)
    expect(query["aria-busy"]).to be_nil
  end

  def choose_option(record)
    find("#oshi-suggestions [data-oshi-id='#{record.id}']").click
    expect(page).to have_css("#oshi-suggestions[hidden]", visible: :all)
    expect(query.value).to eq(record.name)
    expect(page.all("#oshi-search-results input[type=radio]:checked", visible: :all).map(&:value)).to eq([ record.id.to_s ])
    expect(page).to have_css("#oshi-search-status", text: record.name)
  end

  def watch_requests(hold: false)
    page.execute_script(<<~JS, hold)
      window.cOriginalFetch=window.fetch.bind(window);
      window.cQueue=[];window.cRequests={suggestions:[],explicit:[],posts:[]};
      document.documentElement.dataset.cQueueCount="0";
      const hold=arguments[0];
      window.fetch=(input,options={})=>{
        const url=new URL(input instanceof Request?input.url:input.toString(),location.href);
        if((options.method || "GET").toUpperCase()==="POST" && ["/oshis","/user_oshis"].includes(url.pathname))window.cRequests.posts.push(url.pathname);
        if(url.pathname==="/oshis/new" && options.headers?.Accept==="text/html"){
          if(url.searchParams.get("suggest")==="1"){
            window.cRequests.suggestions.push(url.searchParams.get("q"));
            if(hold)return new Promise((resolve,reject)=>{
              window.cQueue.push({url:url.toString(),options,resolve,reject});
              document.documentElement.dataset.cQueueCount=String(window.cQueue.length);
            });
          }else window.cRequests.explicit.push(url.searchParams.get("q"));
        }
        return window.cOriginalFetch(input,options);
      };
    JS
  end

  def queued(count)
    expect(page).to have_css("html[data-c-queue-count='#{count}']")
  end

  def requests
    page.evaluate_script("window.cRequests")
  end

  def release(index, outcome = "normal")
    result = page.evaluate_async_script(<<~JS, index, outcome)
      const index=arguments[0],outcome=arguments[1],done=arguments[arguments.length-1],entry=window.cQueue[index];
      (async()=>{
        if(outcome==="network"){entry.reject(new TypeError("Synthetic network failure"));return done({released:true});}
        if(outcome==="http"){entry.resolve(new Response("Unavailable",{status:503}));return done({released:true});}
        const url=new URL(entry.url);
        if(outcome==="wrong-query")url.searchParams.set("q","別の応答");
        const response=await window.cOriginalFetch(url,{...entry.options,signal:undefined});
        const original=await response.clone().text();
        const doc=new DOMParser().parseFromString(original,"text/html");
        if(response.status!==200 || !doc.querySelector("#oshi-search-results"))throw new Error("Valid suggestion fixture required");
        let text=original;
        if(outcome==="invalid")text="<html>No suggestion payload</html>";
        if(outcome==="count"){
          doc.querySelector("#oshi-search-results").dataset.oshiSearchCount="99";
          text=doc.documentElement.outerHTML;
        }
        const proxy=new Proxy(response,{get(target,key){
          if(key==="text")return ()=>{
            if(outcome==="body")return new Promise(resolve=>{
              entry.bodyResolve=()=>resolve(text);document.documentElement.dataset.cBodyHeld=String(index);
            });
            return Promise.resolve(text);
          };
          const value=Reflect.get(target,key,target);return typeof value==="function"?value.bind(target):value;
        }});
        entry.resolve(proxy);
        done({released:true,status:response.status,validOriginal:true});
      })().catch(error=>done({error:error.name}));
    JS
    expect(result).to include("released" => true)
    result
  end

  def release_body(index)
    page.evaluate_async_script("const done=arguments[arguments.length-1];window.cQueue[arguments[0]].bodyResolve();requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))", index)
  end

  def settle_browser(milliseconds = 380)
    page.evaluate_async_script("const done=arguments[arguments.length-1];setTimeout(()=>done(true),arguments[0])", milliseconds)
  end

  def draft_values
    page.evaluate_script(<<~JS)
      (() => {
        const ids=["oshi_name","oshi_oshi_type","oshi_affiliation","new_user_oshi_started_period","existing_user_oshi_started_period"];
        return Object.fromEntries(ids.map(id=>[id,document.getElementById(id).value]));
      })()
    JS
  end

  def remember_drafts
    @draft_values = draft_values
    page.execute_script(<<~JS)
      window.cDraftInputs=["new_user_oshi_library_images","existing_user_oshi_library_images"].map(id=>document.getElementById(id));
      window.cDraftFiles=window.cDraftInputs.map(input=>input.files);
      window.cDraftForms=window.cDraftInputs.map(input=>input.form);
    JS
  end

  def expect_drafts
    expect(draft_values).to eq(@draft_values)
    expect(page.evaluate_script("window.cDraftInputs.every((input,index)=>input===document.getElementById(input.id)&&input.files===window.cDraftFiles[index]&&input.form===window.cDraftForms[index]&&input.files.length===1)")).to be(true)
  end

  def activity_fields
    page.evaluate_script(<<~JS)
      (() => {
        const result={};
        for(const id of ["activity_title","activity_place","activity_memo","activity_amount","activity_occurred_on","activity_activity_type"])result[id]=document.getElementById(id).value;
        result.lock_version=document.querySelector("input[name='activity[lock_version]']")?.value || null;
        result.emotions=[...document.querySelectorAll("input[name='activity[emotion_ids][]']:checked")].map(input=>input.value);
        return result;
      })()
    JS
  end

  def open_activity(width = 375)
    if width == 1280
      @activity = build(:activity, user: user, oshis_count: 0, title: "保存済み活動")
      Activities::Save.call(activity: @activity, oshi_ids: [ @personal.oshi_id ])
    end
    page.current_window.resize_to(width, 900)
    login
    visit(width == 1280 ? edit_activity_path(@activity) : new_activity_path)
    fill_in "activity_title", with: "入力候補を見ても残す活動"
    fill_in "activity_place", with: "合成の場所"
    fill_in "activity_memo", with: "保持するメモ"
    fill_in "activity_amount", with: "0"
    fill_in "活動日（必須）", with: Date.new(2026, 10, 2)
    select "ライブ・イベント", from: "カテゴリ（必須）"
    check @personal.oshi.name, allow_label_click: true
    check "感動", allow_label_click: true
    attach_file "activity_images", [ Rails.root.join("spec/fixtures/files/image.png"), Rails.root.join("spec/fixtures/files/image.jpg") ]
    expect(page).to have_css("#activity_images[data-image-upload-ready=true]")
    expect(page).to have_css("[data-image-upload-target=previewImages] img", count: 2)
    @activity_fields = activity_fields
    @activity_count = Activity.count
    @image_counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    page.execute_script(<<~JS)
      const input=document.getElementById("activity_images");
      window.cActivityInput=input;window.cActivityForm=input.form;window.cActivityFiles=input.files;
      window.cImageController=window.Stimulus.getControllerForElementAndIdentifier(input.closest("[data-controller~='image-upload']"),"image-upload");
      window.cPreviewURLs=[...document.querySelectorAll("[data-image-upload-target=previewImages] img")].map(img=>img.src);
    JS
    click_button "推しを追加", exact: true
    expect(page).to have_css("#activity-oshi-panel:not([hidden]) input[role=combobox]")
  end

  def expect_activity(personal_checked: true, reconnected: false)
    expect(activity_fields).to eq(@activity_fields)
    expect(page.evaluate_script(<<~JS, reconnected)).to be(true)
      (() => {
        const input=document.getElementById("activity_images"),reconnected=arguments[0];
        const previews=[...document.querySelectorAll("[data-image-upload-target=previewImages] img")];
        return input===window.cActivityInput && input.form===window.cActivityForm && input.files===window.cActivityFiles &&
          input.files.length===2 && window.Stimulus.getControllerForElementAndIdentifier(input.closest("[data-controller~='image-upload']"),"image-upload")===window.cImageController &&
          (reconnected?previews.length===2&&previews.every(img=>img.complete&&img.naturalWidth>0):
            JSON.stringify(previews.map(img=>img.src))===JSON.stringify(window.cPreviewURLs));
      })()
    JS
    expect(Activity.count).to eq(@activity_count)
    expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(@image_counts)
    if personal_checked
      expect(page).to have_checked_field(@personal.oshi.name, type: "checkbox", visible: :all)
    else
      expect(page).to have_unchecked_field(@personal.oshi.name, type: "checkbox", visible: :all)
    end
  end

  def capture_suggestions(width, phase)
    record = page.evaluate_script(<<~JS)
      (() => {
        const input=document.querySelector("input[name=q]"),list=document.getElementById("oshi-suggestions"),button=document.querySelector("[data-oshi-registration-target=searchButton]");
        const bounds=list.getBoundingClientRect(),buttonBounds=button.getBoundingClientRect();
        return {viewport_width:innerWidth,client_width:document.documentElement.clientWidth,scroll_width:document.documentElement.scrollWidth,
          expanded:input.getAttribute("aria-expanded"),controls_match:input.getAttribute("aria-controls")===list.id,
          active_id:input.getAttribute("aria-activedescendant"),active_exists:!input.hasAttribute("aria-activedescendant")||!!document.getElementById(input.getAttribute("aria-activedescendant")),
          focused_query:document.activeElement===input,option_count:list.children.length,
          option_heights:[...list.children].map(option=>option.getBoundingClientRect().height),
          popup_visible:!list.hidden,popup_left:bounds.left,popup_right:bounds.right,placement:list.dataset.placement,
          search_button_uncovered:list.hidden||bounds.top>=buttonBounds.bottom||bounds.bottom<=buttonBounds.top,
          selected_ids:[...document.querySelectorAll("#oshi-search-results input[type=radio]:checked")].map(input=>input.value),
          posted_ids:new FormData(document.querySelector("#oshi-existing form[action$='/user_oshis']")).getAll("oshi_id"),
          status:document.getElementById("oshi-search-status").textContent};
      })()
    JS
    expect(record["viewport_width"]).to eq(width)
    expect(record["scroll_width"]).to be <= record["client_width"]
    expect(record["controls_match"]).to be(true)
    expect(record["active_exists"]).to be(true)
    expect(record["search_button_uncovered"]).to be(true)
    expect(record["selected_ids"].size).to be <= 1
    expect(record["posted_ids"]).to eq(record["selected_ids"])
    if record["popup_visible"]
      expect(record["option_heights"]).to all(be >= 44)
      expect(record["popup_left"]).to be >= 0
      expect(record["popup_right"]).to be <= record["client_width"]
    end
    browser = page.driver.browser
    geometry = page.evaluate_script("({client:document.documentElement.clientWidth,x:scrollX,y:scrollY,focus:document.activeElement.id})")
    shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
    expect(page.evaluate_script("({client:document.documentElement.clientWidth,x:scrollX,y:scrollY,focus:document.activeElement.id})")).to eq(geometry)
    record["capture_kind"] = "viewport"
    record["capture_geometry_preserved"] = true
    directory = Rails.root.join("tmp/oshi-typeahead-c-20261030-ui", ENV.fetch("OSHI_SUGGEST_CAPTURE_LABEL", "local"))
    FileUtils.mkdir_p(directory)
    path = directory.join("#{width}-#{phase}.png")
    File.binwrite(path, Base64.strict_decode64(shot.fetch("data")))
    File.write(path.sub_ext(".json"), JSON.pretty_generate(record.merge("screenshot" => path.to_s)))
  end

  [ 375, 1280 ].each do |width|
    it "chooses keyboard and pointer suggestions without changing either registration draft at#{width}px" do
      setup_candidates
      open_registration(width)
      within("#oshi-registration") do
        fill_in "oshi_name", with: "本人が入力した名前"
        select "声優", from: "種別（必須）"
        fill_in "oshi_affiliation", with: "保持する作品"
        select_started_period "2021/04"
        attach_file "登録画像", Rails.root.join("spec/fixtures/files/image.png")
        expect(page).to have_css("input[type=file][data-image-upload-ready=true]")
      end
      within("#oshi-existing form[action='#{user_oshis_path}']") do
        select_started_period "2020/05"
        attach_file "登録画像", Rails.root.join("spec/fixtures/files/image.jpg")
        expect(page).to have_css("input[type=file][data-image-upload-ready=true]")
      end
      remember_drafts
      counts = [ Oshi.count, UserOshi.count ]
      watch_requests
      type_query("予測候補")
      position = page.evaluate_script("({focus:document.activeElement.id,y:scrollY})")
      wait_suggestions
      expect(options.size).to eq(5)
      expect(page).not_to have_text(@private.name)
      expect(page).not_to have_text("表示しない候補画像")
      expect(find("#oshi-suggestion-#{@candidate.id} img")[:src]).to end_with(common_oshi_image_path(@common.image.attachment))
      expect(page.evaluate_script("({focus:document.activeElement.id,y:scrollY})")).to eq(position)
      query.send_keys(:arrow_down, :arrow_down)
      expect(query["aria-activedescendant"]).to eq("oshi-suggestion-#{@candidate.id}")
      expect(page.all("#oshi-search-results input:checked", visible: :all)).to be_empty
      capture_suggestions(width, "full-options")
      page.execute_script("document.querySelector('input[name=q]').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',repeat:true,bubbles:true}))")
      expect(query["aria-expanded"]).to eq("true")
      query.send_keys(:enter)
      expect(query.value).to eq(@candidate.name)
      expect(query["aria-expanded"]).to eq("false")
      expect(requests["posts"]).to be_empty
      expect_drafts
      query.send_keys(:tab)
      expect(requests["posts"]).to be_empty
      type_query("予測候補")
      wait_suggestions
      choose_option(@long)
      expect_drafts
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      expect(requests["posts"]).to be_empty
      capture_suggestions(width, "full-selected")
      expect(page.evaluate_script("document.querySelector(\"#oshi-existing form[action$='/user_oshis']\").checkValidity()")).to be(true)
      within("#oshi-existing form[action='#{user_oshis_path}']") { click_button "選んだ推しを追加" }
      expect(page).to have_css("main h1", exact_text: "推し一覧")
      saved = user.user_oshis.find_by!(oshi: @long)
      expect(saved.started_period).to eq("2020/05")
      expect(saved.image_library.size).to eq(1)
      expect([ Oshi.count, UserOshi.count ]).to eq([ counts[0], counts[1] + 1 ])
    end

    it "keeps the activity DOM, version, FileList and preview through input selection at#{width}px" do
      setup_candidates
      open_activity(width)
      watch_requests
      type_query("予測候補")
      wait_suggestions
      capture_suggestions(width, "inline-options")
      expect_activity
      choose_option(@candidate)
      expect(requests["posts"]).to be_empty
      expect_activity
      registrations = UserOshi.count
      within("#oshi-existing form[action='#{user_oshis_path}']") do
        select_started_period "2022/04"
        click_button I18n.t("ui.activity_panel.register_select")
      end
      expect(page).to have_checked_field(@candidate.name, type: "checkbox", visible: :all)
      expect_activity
      expect(UserOshi.count).to eq(registrations + 1)
      expect(page).to have_css("#oshi-search-status", text: "追加済み")
      within("#oshi-existing form[action='#{user_oshis_path}']") do
        expect(page).to have_button(I18n.t("ui.activity_panel.select"))
        click_button I18n.t("ui.activity_panel.select")
      end
      expect(UserOshi.count).to eq(registrations + 1)
      expect_activity
      expect(requests["posts"]).to eq([ "/user_oshis" ])
    end
  end

  it "debounces rapid input and suppresses composition Enter while keeping explicit Enter available" do
    setup_candidates
    open_registration
    watch_requests(hold: true)
    page.execute_script(<<~JS)
      const input=document.querySelector("input[name=q]");
      for(const value of ["一つ前","最後の入力"]){input.value=value;input.dispatchEvent(new Event("input",{bubbles:true}));}
    JS
    queued(1)
    expect(requests["suggestions"]).to eq([ "最後の入力" ])
    page.execute_script(<<~JS)
      const input=document.querySelector("input[name=q]");
      input.dispatchEvent(new CompositionEvent("compositionstart",{bubbles:true}));
      input.value="変換中の候補";input.dispatchEvent(new Event("input",{bubbles:true}));
      input.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",keyCode:229,isComposing:true,bubbles:true}));
      input.form.requestSubmit();
    JS
    settle_browser
    queued(1)
    expect(requests["explicit"]).to be_empty
    page.execute_script(<<~JS)
      const input=document.querySelector("input[name=q]");
      input.dispatchEvent(new CompositionEvent("compositionend",{bubbles:true}));
      input.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",keyCode:13,bubbles:true}));
      input.form.requestSubmit();
    JS
    queued(2)
    expect(requests["explicit"]).to be_empty
    expect(page).to have_field("oshi_name", with: "")
    page.execute_script("document.querySelector('input[name=q]').dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',bubbles:true}))")
    query.send_keys(:enter)
    expect(page).to have_field("oshi_name", with: "変換中の候補")
    expect(requests["explicit"]).to eq([ "変換中の候補" ])
    release(0)
    release(1)
    expect(page).to have_field("oshi_name", with: "変換中の候補")
  end

  it "rejects reversed results and a body completed after the query changed without moving focus or scroll" do
    setup_candidates
    open_registration
    watch_requests(hold: true)
    type_query(@candidate.name)
    queued(1)
    release(0, "body")
    expect(page).to have_css("html[data-c-body-held='0']")
    type_query(@second.name)
    queued(2)
    position = page.evaluate_script("({focus:document.activeElement.id,y:scrollY})")
    release(1)
    wait_suggestions(@second.name)
    expect(options.map { |option| option["data-oshi-id"] }).to eq([ @second.id.to_s ])
    release_body(0)
    expect(options.map { |option| option["data-oshi-id"] }).to eq([ @second.id.to_s ])
    expect(page.evaluate_script("({focus:document.activeElement.id,y:scrollY})")).to eq(position)
    expect(page).to have_field("oshi_name", with: "")
    type_query(@long.name)
    queued(3)
    type_query(@candidate.name)
    queued(4)
    release(3)
    wait_suggestions(@candidate.name)
    release(2)
    expect(options.map { |option| option["data-oshi-id"] }).to eq([ @candidate.id.to_s ])
    expect(requests["posts"]).to be_empty
  end

  it "keeps typing errors and zero results separate from confirmed name handoff" do
    setup_candidates
    open_registration
    confirm_search("確定した未登録名")
    expect(page).to have_field("oshi_name", with: "確定した未登録名")
    watch_requests(hold: true)
    %w[network http invalid wrong-query count normal].each_with_index do |outcome, index|
      value = "まだ未登録の入力#{index}"
      type_query(value)
      queued(index + 1)
      release(index, outcome)
      state = outcome == "normal" ? "empty" : "error"
      expect(page).to have_css("#oshi-search-results[data-oshi-search-state='#{state}']", visible: :all)
      expect(page).to have_field("oshi_name", with: "確定した未登録名")
      expect(page).to have_css("input[name=q]:focus")
      expect(query["aria-expanded"]).to eq("false")
      expect(requests["posts"]).to be_empty
    end
    capture_suggestions(375, "typing-empty")
    click_button "検索", exact: true
    expect(page).to have_field("oshi_name", with: "まだ未登録の入力5")
    expect(page).to have_css("#oshi_name:focus")
  end

  it "clears an old automatic name only on a subsequent confirmed matching search" do
    setup_candidates
    open_registration
    confirm_search("自動で引き継いだ未登録名")
    expect(page).to have_field("oshi_name", with: "自動で引き継いだ未登録名")
    type_query("予測候補")
    wait_suggestions
    expect(page).to have_field("oshi_name", with: "自動で引き継いだ未登録名")
    click_button "検索", exact: true
    expect(page).to have_field("oshi_name", with: "")
    expect(page).to have_css("#oshi-search-status", text: "前の検索の登録名をクリアしました。")
  end

  after do
    @auth_tab&.close
  end

  def prepare_auth_tab
    @auth_tab = open_new_window
    within_window(@auth_tab) do
      visit root_path
      page.execute_script("window.name='c-auth-fixture'")
    end
    page.execute_script("window.cAuthTab=window.open('', 'c-auth-fixture')")
    page.driver.browser.execute_cdp("Page.bringToFront")
    expect(page.evaluate_script("document.visibilityState")).to eq("visible")
  end

  def change_auth(account = nil)
    result = page.evaluate_async_script(<<~JS, account&.email)
      const done=arguments[arguments.length-1],email=arguments[0],tab=window.cAuthTab;
      (async()=>{
        const csrf=tab.document.querySelector('meta[name="csrf-token"]')?.content;
        let response=await tab.fetch("/users/sign_out",{method:"DELETE",credentials:"same-origin",headers:{"X-CSRF-Token":csrf || ""}});
        let html=await response.text();
        if(email){
          const token=new DOMParser().parseFromString(html,"text/html").querySelector('meta[name="csrf-token"]')?.content;
          response=await tab.fetch("/users/sign_in",{method:"POST",credentials:"same-origin",
            headers:{"Content-Type":"application/x-www-form-urlencoded","X-CSRF-Token":token || ""},
            body:new URLSearchParams({"user[email]":email,"user[password]":"password123"})});
          html=await response.text();
        }
        done({status:response.status,authenticated:html.includes(">ホーム</h1>")});
      })().catch(error=>done({error:error.name}));
    JS
    expect(result).to eq({ "status" => account.nil? ? 204 : 200, "authenticated" => !account.nil? })
  end

  def hold_final_verification
    page.execute_script(<<~JS)
      window.cVerificationFetch=window.fetch;window.cVerificationHeld=false;
      window.fetch=async(input,options={})=>{
        const response=await window.cVerificationFetch(input,options);
        const url=new URL(input instanceof Request?input.url:input.toString(),location.href);
        if(!window.cVerificationHeld && url.pathname==="/oshis" && options.headers?.Accept==="application/json"){
          await response.clone().text();window.cVerificationHeld=true;window.cVerificationStatus=response.status;
          return new Promise(resolve=>{window.cReleaseVerification=()=>resolve(response)});
        }
        return response;
      };
    JS
  end

  def wait_verification
    expect(page.evaluate_async_script(<<~JS)).to be(true)
      const done=arguments[0],end=Date.now()+5000;
      function poll(){if(window.cVerificationHeld)return done(true);if(Date.now()>end)return done(false);setTimeout(poll,10)}poll();
    JS
    expect(page.evaluate_script("window.cVerificationStatus")).to eq(200)
  end

  def remember_result
    page.execute_script(<<~JS)
      window.cRememberedRoot=document.querySelector("[data-controller='oshi-registration']");
      window.cRememberedResult=document.getElementById("oshi-search-results").innerHTML;
      window.cRememberedName=document.getElementById("oshi_name").value;
    JS
  end

  def expect_result_unchanged
    expect(page.evaluate_script(<<~JS)).to be(true)
      document.querySelector("[data-controller='oshi-registration']")===window.cRememberedRoot &&
        document.getElementById("oshi-search-results").innerHTML===window.cRememberedResult &&
        document.getElementById("oshi_name").value===window.cRememberedName
    JS
    expect(page).to have_css("#oshi-suggestions[hidden]", visible: :all)
    expect(requests["posts"]).to be_empty
  end

  it "cancels suggestions on Escape, Tab, blur and a reserved timer without choosing or posting" do
    setup_candidates
    open_registration
    watch_requests(hold: true)
    type_query("予測候補")
    queued(1)
    release(0)
    wait_suggestions
    query.send_keys(:arrow_down)
    query.send_keys(:escape)
    expect(query["aria-expanded"]).to eq("false")
    expect(query["aria-activedescendant"]).to be_nil
    expect(page.all("#oshi-search-results input:checked", visible: :all)).to be_empty
    type_query(@candidate.name)
    queued(2)
    query.send_keys(:tab)
    remember_result
    release(1)
    expect_result_unchanged
    type_query(@second.name)
    queued(3)
    fill_in "oshi_name", with: "本人の手入力"
    remember_result
    release(2)
    expect_result_unchanged
    query.click
    page.execute_script(<<~JS)
      const input=document.querySelector("input[name=q]");
      input.value="予約を中断する";input.dispatchEvent(new Event("input",{bubbles:true}));
      input.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}));
    JS
    settle_browser
    queued(3)
    expect(page).to have_field("oshi_name", with: "本人の手入力")
    expect(query["aria-expanded"]).to eq("false")
    expect(requests["posts"]).to be_empty
  end

  it "discards work through hidden visibility and persisted page restore without restarting a lookup" do
    setup_candidates
    open_registration
    watch_requests(hold: true)
    type_query(@candidate.name)
    queued(1)
    page.execute_script(<<~JS)
      window.cVisibilityDescriptor=Object.getOwnPropertyDescriptor(document,"visibilityState");
      Object.defineProperty(document,"visibilityState",{configurable:true,get:()=>"hidden"});
      document.dispatchEvent(new Event("visibilitychange"));
      Object.defineProperty(document,"visibilityState",{configurable:true,get:()=>"visible"});
      document.dispatchEvent(new Event("visibilitychange"));
    JS
    remember_result
    release(0)
    expect_result_unchanged
    type_query(@second.name)
    queued(2)
    page.execute_script('window.dispatchEvent(new PageTransitionEvent("pageshow",{persisted:true}))')
    remember_result
    release(1)
    expect_result_unchanged
    settle_browser
    queued(2)
    expect(page).to have_field("oshi_name", with: "")
  ensure
    page.execute_script("if(window.cVisibilityDescriptor)Object.defineProperty(document,'visibilityState',window.cVisibilityDescriptor);else delete document.visibilityState")
  end

  it "drops pending results on real reconnect and Turbo Back while keeping an unknown registration name" do
    setup_candidates
    open_registration
    page.execute_script("document.getElementById('oshi_name').value='由来不明の保持名'")
    watch_requests(hold: true)
    type_query(@candidate.name)
    queued(1)
    page.execute_script(<<~JS)
      window.cRoot=document.querySelector("[data-controller='oshi-registration']");
      window.cAnchor=document.createComment("C reconnect");window.cRoot.before(window.cAnchor);window.cRoot.remove();
    JS
    page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
    page.execute_script("window.cAnchor.replaceWith(window.cRoot)")
    expect(page).to have_css("input[role=combobox][aria-expanded=false]")
    remember_result
    release(0)
    expect_result_unchanged
    expect(page).to have_field("oshi_name", with: "由来不明の保持名")
    type_query(@second.name)
    queued(2)
    click_link "推し一覧へ戻る"
    expect(page).to have_css("main h1", exact_text: "推し一覧")
    page.go_back
    expect(page).to have_current_path(new_oshi_path)
    expect(page).to have_css("input[role=combobox][aria-expanded=false]")
    expect(page).to have_field("oshi_name", with: "由来不明の保持名")
    remember_result
    release(1)
    expect_result_unchanged
    settle_browser
    queued(2)
  end

  it "protects same-text edits and deliberate blank names from typing and confirmed searches" do
    setup_candidates
    open_registration
    confirm_search("同値編集の自動名")
    expect(page).to have_field("oshi_name", with: "同値編集の自動名")
    fill_in "oshi_name", with: "一度編集した名前"
    fill_in "oshi_name", with: "同値編集の自動名"
    type_query(@candidate.name)
    wait_suggestions(@candidate.name)
    expect(page).to have_field("oshi_name", with: "同値編集の自動名")
    click_button "検索", exact: true
    expect(page).to have_css("#oshi-search-results[data-oshi-search-mode=explicit]")
    expect(page).to have_field("oshi_name", with: "同値編集の自動名")
    fill_in "oshi_name", with: ""
    type_query("意図して空欄にしたまま")
    expect(page).to have_css("#oshi-search-results[data-oshi-search-mode=suggestions][data-oshi-search-state=empty]", visible: :all)
    expect(page).to have_field("oshi_name", with: "")
    click_button "検索", exact: true
    expect(page).to have_css("#oshi-search-results[data-oshi-search-mode=explicit][data-oshi-search-state=empty]")
    expect(page).to have_field("oshi_name", with: "")
  end

  %w[switch logout].each_with_index do |actor, index|
    it "rejects a suggestion body completed after #{actor} without changing activity input" do
      setup_candidates
      width = index.zero? ? 375 : 1280
      open_activity(width)
      prepare_auth_tab
      watch_requests(hold: true)
      type_query(@pending.name)
      queued(1)
      release(0, "body")
      expect(page).to have_css("html[data-c-body-held='0']")
      remember_result
      change_auth(actor == "switch" ? create(:user) : nil)
      release_body(0)
      expect(page).to have_text(I18n.t("ui.activity_panel.context_error"))
      expect_result_unchanged
      expect_activity
      expect(page).to have_css("#oshi-search-results[data-oshi-search-state=paused]", visible: :all)
      capture_suggestions(width, "actor-#{actor}")
    end
  end

  %w[query name selection close reconnect].each_with_index do |intent, index|
    it "ignores typing HTML after #{intent} changes during final actor verification" do
      setup_candidates
      open_activity(index.even? ? 375 : 1280)
      watch_requests(hold: true)
      hold_final_verification
      type_query(@candidate.name)
      queued(1)
      release(0)
      wait_verification
      case intent
      when "query"
        type_query("さらに新しい入力")
        queued(2)
        release(1)
        expect(page).to have_css("#oshi-search-results[data-oshi-search-mode=suggestions][data-oshi-search-query='さらに新しい入力']", visible: :all)
      when "name"
        fill_in "oshi_name", with: "本人が書いた保持名"
      when "selection"
        page.execute_script(<<~JS)
          const input=document.querySelector("input[type='checkbox'][name='activity[oshi_ids][]']");
          input.checked=false;input.dispatchEvent(new Event("change",{bubbles:true}));
        JS
      when "close"
        click_button I18n.t("ui.activity_panel.close")
      when "reconnect"
        page.execute_script(<<~JS)
          window.cPanelRoot=document.querySelector("[data-controller~='activity-oshi-panel']");
          window.cPanelAnchor=document.createComment("C panel reconnect");window.cPanelRoot.before(window.cPanelAnchor);window.cPanelRoot.remove();
        JS
        page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
        page.execute_script("window.cPanelAnchor.replaceWith(window.cPanelRoot)")
        page.evaluate_async_script("const done=arguments[0];requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
      end
      remember_result
      page.evaluate_async_script("const done=arguments[0];window.cReleaseVerification();requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
      expect(page).to have_css("#oshi-search-results:not([aria-busy])", visible: :all)
      expect_result_unchanged
      expect_activity(personal_checked: intent != "selection", reconnected: intent == "reconnect")
    end
  end
end
