require "rails_helper"
require "active_storage/service/disk_service"
require "vips"
require "digest"
require "tmpdir"
require "json"
require "base64"

RSpec.describe "Activity image previews", type: :system, activity_preview: true do
  let(:user) { create(:user) }
  let(:registration) { create(:user_oshi, user: user, oshi: create(:oshi, :approved)) }

  around do |example|
    Dir.mktmpdir("activity-preview-", Rails.root.join("tmp")) do |directory|
      @directory = Pathname.new(directory)
      example.run
    end
  end

  before do
    service = ActiveStorage::Service::DiskService.new(root: @directory.join("storage"))
    service.name = "test"
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)
    allow(ActiveStorage::Blob).to receive(:services).and_return({ "test" => service })
    @large = synthetic_png("large-blue.png", 3000, 2000, [ 24, 90, 210 ])
    @small = synthetic_png("small-green.png", 80, 60, [ 30, 160, 80 ])
    @saved = synthetic_png("saved-red.png", 64, 48, [ 210, 48, 45 ])
  end

  def synthetic_png(name, width, height, color)
    path = @directory.join(name)
    Vips::Image.black(width, height, bands: 3).new_from_image(color).copy(interpretation: :srgb).write_to_file(path.to_s, compression: 9, strip: true)
    path
  end

  def open_activity(mode = "new", width: 1280)
    registration
    @activity = nil
    if mode == "edit"
      @activity = build(:activity, user: user, oshis_count: 0, title: "保存済み合成活動")
      @activity.activity_oshis.build(oshi: registration.oshi)
      @activity.images.attach(io: File.open(@saved, "rb"), filename: "saved-red.png", content_type: "image/png", identify: false)
      @activity.save!
    end
    page.current_window.resize_to(width, 900)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
    visit(mode == "edit" ? edit_activity_path(@activity) : new_activity_path)
    fill_in "activity_title", with: "保持する未保存のタイトル"
    fill_in "activity_place", with: "保持する場所"
    fill_in "activity_memo", with: "保持するメモ\n2行目"
    fill_in "activity_amount", with: "0"
    check registration.oshi.name, allow_label_click: true
    @fields = fields
    @saved_images = page.evaluate_script("Array.from(document.querySelectorAll('main form section:not([data-image-upload-target]) img')).map(img => img.getAttribute('src'))")
    install_url_monitor
  end

  def fields
    page.evaluate_script(<<~JS)
      (() => {
        const result = {};
        for (const id of ["activity_title","activity_place","activity_memo","activity_amount","activity_occurred_on"]) result[id] = document.getElementById(id).value;
        result.oshi_ids = [...document.querySelectorAll("input[name='activity[oshi_ids][]']:checked")].map(input => input.value);
        return result;
      })()
    JS
  end

  def install_url_monitor
    page.execute_script(<<~JS)
      window.previewURLs = {created: [], revoked: []};
      const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
      URL.createObjectURL = file => {
        const url = create(file);
        window.previewURLs.created.push(url);
        return url;
      };
      URL.revokeObjectURL = url => {
        window.previewURLs.revoked.push(url);
        return revoke(url);
      };
    JS
  end

  def live_urls
    page.evaluate_script("window.previewURLs.created.filter(url => !window.previewURLs.revoked.includes(url))")
  end

  def file_details(previews: false)
    page.evaluate_async_script(<<~JS, previews)
      const previews = arguments[0], done = arguments[1];
      (async () => {
        const sources = previews
          ? [...document.querySelectorAll("[data-image-upload-target='previewImages'] img")]
          : [...document.querySelector("#activity_images").files];
        return await Promise.all(sources.map(async source => {
          const file = previews ? await (await fetch(source.src)).blob() : source;
          const bitmap = await createImageBitmap(file);
          const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
          const result = {bytes: file.size, type: file.type, width: bitmap.width, height: bitmap.height,
            sha256: [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2,"0")).join("")};
          if (!previews) result.name = source.name;
          bitmap.close();
          return result;
        }));
      })().then(done).catch(error => done({error: error.name}));
    JS
  end

  def expect_preview_matches(count)
    expect(page).to have_css("[data-image-upload-target='preview']:not([hidden]) img", count: count, wait: 20)
    expect(page.evaluate_async_script(<<~JS)).to be(true)
      const done=arguments[0];
      Promise.all([...document.querySelectorAll("[data-image-upload-target='previewImages'] img")].map(img =>
        img.complete ? Promise.resolve(img.naturalWidth > 0) : new Promise(resolve => {
          img.addEventListener("load",()=>resolve(true),{once:true});
          img.addEventListener("error",()=>resolve(false),{once:true});
        })
      )).then(values=>done(values.every(Boolean)));
    JS
    files = file_details
    expect(file_details(previews: true)).to eq(files.map { |file| file.except("name") })
    expect(page.all("[data-image-upload-target='previewImages'] img").map { |img| img["alt"] }).to eq(
      files.each_with_index.map { |file, index| I18n.t("ui.activity.preview_alt", index: index + 1, filename: file.fetch("name")) }
    )
    expect(live_urls).to match_array(page.all("[data-image-upload-target='previewImages'] img").map { |img| img["src"] })
    expect(fields).to eq(@fields)
    expect(page.evaluate_script("Array.from(document.querySelectorAll('main form section:not([data-image-upload-target]) img')).map(img => img.getAttribute('src'))")).to eq(@saved_images)
    files
  end

  def choose(paths)
    attach_file "activity_images", Array(paths)
    expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
  end

  def settle
    page.evaluate_async_script("const done=arguments[0]; requestAnimationFrame(()=>requestAnimationFrame(()=>done(true)))")
  end

  def detach
    page.execute_script(<<~JS)
      window.detachedArea=document.querySelector("#activity_images").closest("[data-controller~='image-upload']");
      window.anchor=document.createComment("preview lifecycle");
      window.detachedArea.before(window.anchor); window.detachedArea.remove();
    JS
    settle
    expect(page.evaluate_script("!window.Stimulus.getControllerForElementAndIdentifier(window.detachedArea,'image-upload')")).to be(true)
  end

  def reconnect
    page.execute_script("window.anchor.replaceWith(window.detachedArea)")
    settle
  end

  def delay_first_bitmap
    page.execute_script(<<~JS)
      const original=createImageBitmap;
      let first=true;
      window.createImageBitmap=(...args)=>{
        if(!first)return original(...args);
        first=false;
        return new Promise((resolve,reject)=>{
          window.releaseBitmap=()=>original(...args).then(resolve,reject);
        });
      };
    JS
  end

  [ 375, 1280 ].each do |width|
    %w[new edit].each do |mode|
      it "shows the actual new and unchanged candidates in #{mode} at #{width}px", :preview_capture do
        open_activity(mode, width: width)
        counts = [ Activity.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
        original_sha = Digest::SHA256.file(@large).hexdigest
        choose([ @large, @small ])
        candidates = expect_preview_matches(2)
        expect(candidates[0]).to include("width" => 2560, "height" => 1706)
        expect(candidates[0]["sha256"]).not_to eq(original_sha)
        expect(candidates[1]["sha256"]).to eq(Digest::SHA256.file(@small).hexdigest)
        expect(Digest::SHA256.file(@large).hexdigest).to eq(original_sha)
        expect([ Activity.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]).to eq(counts)
        expect(page).to have_css("#activity-image-status", text: "1枚を縮小しました。1枚は元のファイルを使用します。送信できます。", exact_text: true)
        expect(page).to have_css("[data-image-upload-target='preview'] h2", text: "今回追加する画像（未保存）", exact_text: true)
        expect(page).to have_no_css("[data-image-upload-target='preview'][aria-live], [data-image-upload-target='preview'] [aria-live]")
        capture_preview(mode, width, candidates)
      end
    end
  end

  it "follows reselect, clear, and whole-batch validation failure" do
    open_activity
    choose([ @large, @small ])
    expect_preview_matches(2)
    old_urls = live_urls
    choose(@small)
    expect_preview_matches(1)
    expect(live_urls & old_urls).to be_empty
    page.execute_script("const input=document.querySelector('#activity_images'); input.value=''; input.dispatchEvent(new Event('change',{bubbles:true}))")
    expect(page).to have_css("#activity_images[data-image-upload-ready='false']")
    expect(live_urls).to be_empty
    expect(page).to have_no_css("[data-image-upload-target='preview'] img", visible: :all)
    choose(@small)
    invalid = @directory.join("invalid.txt")
    File.write(invalid, "artificial invalid image")
    attach_file "activity_images", [ @small, invalid ]
    expect(page).to have_css("#activity-image-status[role='alert']", text: "JPEG・PNG・WebP")
    expect(file_details).to eq([])
    expect(live_urls).to be_empty
    expect(page).to have_no_css("[data-image-upload-target='preview'] img", visible: :all)
    expect(fields).to eq(@fields)
  end

  [ false, true ].each do |cross_connection|
    it "ignores delayed old completion with reconnect=#{cross_connection}" do
      open_activity
      delay_first_bitmap
      attach_file "activity_images", @large
      expect(page).to have_button("記録する", disabled: true)
      expect(page.evaluate_async_script("const done=arguments[0], end=Date.now()+3000; function poll(){if(window.releaseBitmap)return done(true); if(Date.now()>end)return done(false);setTimeout(poll,10)} poll()")).to be(true)
      page.execute_script("window.oldQueue=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('#activity_images').closest('[data-controller]'),'image-upload').queue")
      expect(live_urls).to be_empty
      if cross_connection
        detach
        reconnect
      end
      attach_file "activity_images", @small
      if cross_connection
        expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
        expect_preview_matches(1)
      else
        expect(page).to have_no_css("[data-image-upload-target='preview'] img", visible: :all)
      end
      page.evaluate_async_script("const done=arguments[0]; window.releaseBitmap(); window.oldQueue.then(()=>done(true),()=>done(false))")
      expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
      expect(expect_preview_matches(1).first["name"]).to eq("small-green.png")
    end
  end


  it "rechecks the same pending candidates after reconnect without reselection" do
    open_activity
    page.execute_script(<<~JS)
      const original=createImageBitmap;
      window.pendingDecodes=[];
      window.createImageBitmap=(...args)=>{
        if(window.pendingDecodes.length>=2)return original(...args);
        return new Promise((resolve,reject)=>{
          window.pendingDecodes.push(()=>original(...args).then(resolve,reject));
        });
      };
    JS
    attach_file "activity_images", @large
    expect(page).to have_button("記録する", disabled: true)
    expect(page.evaluate_async_script("const done=arguments[0],end=Date.now()+3000;function poll(){if(window.pendingDecodes.length===1)return done(true);if(Date.now()>end)return done(false);setTimeout(poll,10)}poll()")).to be(true)
    page.execute_script("window.oldQueue=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('#activity_images').closest('[data-controller]'),'image-upload').queue")
    detach
    reconnect
    expect(page.evaluate_async_script("const done=arguments[0],end=Date.now()+3000;function poll(){if(window.pendingDecodes.length===2)return done(true);if(Date.now()>end)return done(false);setTimeout(poll,10)}poll()")).to be(true)
    expect(page).to have_css("#activity_images[data-image-upload-ready='false']")
    expect(page).to have_button("記録する", disabled: true)
    expect(page.evaluate_script("document.querySelector('#activity_images').files[0].name")).to eq("large-blue.png")
    expect(fields).to eq(@fields)
    expect(live_urls).to be_empty
    page.evaluate_async_script("const done=arguments[0];window.pendingDecodes[0]();window.oldQueue.then(()=>done(true),()=>done(false))")
    expect(page).to have_button("記録する", disabled: true)
    expect(page).to have_css("#activity_images[data-image-upload-ready='false']")
    page.execute_script("window.pendingDecodes[1]()")
    expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
    expect(expect_preview_matches(1).first).to include("name" => "large-blue.png", "width" => 2560, "height" => 1706)
    expect(page).to have_button("記録する", disabled: false)
  end

  %w[new edit].each do |mode|
    it "preserves #{mode} candidates and inputs through reconnect and Turbo back" do
      open_activity(mode)
      choose([ @large, @small ])
      candidates = expect_preview_matches(2)
      first_urls = live_urls
      detach
      expect(live_urls).to be_empty
      reconnect
      expect(expect_preview_matches(2)).to eq(candidates)
      expect(live_urls & first_urls).to be_empty
      second_urls = live_urls
      click_link(mode == "new" ? "活動記録一覧へ戻る" : "詳細へ戻る")
      expect(page).to have_current_path(mode == "new" ? activities_path : activity_path(@activity))
      expect(live_urls).to be_empty
      page.go_back
      expect(page).to have_css("#activity_images[data-image-upload-ready='true']")
      expect(expect_preview_matches(2)).to eq(candidates)
      expect(live_urls & second_urls).to be_empty
      expect(fields).to eq(@fields)
    end
  end

  %w[url dom decode].each do |failure|
    it "keeps valid candidates and other inputs when only #{failure} preview display fails" do
      open_activity
      page.execute_script(case failure
      when "url"
        "URL.createObjectURL=()=>{throw new Error('artificial URL failure')}"
      when "dom"
        "document.querySelector('[data-image-upload-target=previewImages]').append=()=>{throw new Error('artificial DOM failure')}"
      when "decode"
        "const original=URL.createObjectURL; URL.createObjectURL=()=>original(new Blob(['artificial invalid image'],{type:'image/png'}))"
      end)
      choose(@small)
      expect(page).to have_css("#activity-image-status[role='alert']", text: I18n.t("ui.activity.preview_error"), exact_text: true)
      expect(file_details.first).to include("name" => "small-green.png", "sha256" => Digest::SHA256.file(@small).hexdigest)
      expect(fields).to eq(@fields)
      expect(page).to have_button("記録する", disabled: false)
      expect(page).to have_no_css("[data-image-upload-target='preview'] img", visible: :all)
      expect(live_urls).to be_empty
    end
  end

  it "does not create preview DOM or URLs for the existing other upload forms" do
    open_activity
    [ edit_profile_path, edit_user_oshi_path(registration) ].each do |path|
      visit path
      install_url_monitor
      expect(page).to have_no_css("[data-image-upload-target='preview']", visible: :all)
      inputs = page.all("[data-controller~='image-upload'] input[type='file']")
      expect(inputs).not_to be_empty
      inputs.each do |input|
        attach_file input[:id], @small
        expect(page).to have_css("##{input[:id]}[data-image-upload-ready='true']", wait: 20)
      end
      expect(page.evaluate_script("window.previewURLs.created.length")).to eq(0)
      expect(inputs.map { |input| page.evaluate_script("arguments[0].files[0].name", input) }).to all(eq("small-green.png"))
    end

    candidate = create(:oshi, :approved, name: "画像フォーム確認用の候補")
    visit new_oshi_path(q: candidate.name)
    install_url_monitor
    expect(page).to have_no_css("[data-image-upload-target='preview']", visible: :all)
    existing_input = find("#oshi-existing input[type='file']")
    attach_file existing_input[:id], @small
    expect(page).to have_css("##{existing_input[:id]}[data-image-upload-ready='true']", wait: 20)
    click_link I18n.t("ui.oshi.new_heading"), exact: true
    new_input = find("#oshi-registration input[type='file']")
    attach_file new_input[:id], @small
    expect(page).to have_css("##{new_input[:id]}[data-image-upload-ready='true']", wait: 20)
    expect(page.evaluate_script("window.previewURLs.created.length")).to eq(0)
    expect([ existing_input, new_input ].map { |input| page.evaluate_script("arguments[0].files[0].name", input) }).to all(eq("small-green.png"))
  end

  it "clears an over-limit batch before creating previews without changing other inputs" do
    open_activity
    choose(@small)
    expect_preview_matches(1)
    padded = [ 5.megabytes, 5.megabytes + 1 ].each_with_index.map do |bytes, index|
      path = @directory.join("padded-#{index}.png")
      File.binwrite(path, File.binread(@small).ljust(bytes, "\0"))
      path
    end
    attach_file "activity_images", padded
    expect(page).to have_css("#activity-image-status[role='alert']", text: "1回に送信する画像の合計を10 MiB以下にしてください。")
    expect(file_details).to eq([])
    expect(page).to have_css("#activity_images[data-image-upload-ready='false']")
    expect(page).to have_no_css("[data-image-upload-target='preview'] img", visible: :all)
    expect(live_urls).to be_empty
    expect(fields).to eq(@fields)
  end

  def capture_preview(mode, width, candidates)
    focus = page.evaluate_script("document.activeElement.id")
    page.execute_script("document.querySelector('[data-image-upload-target=preview]').scrollIntoView({block:'center',behavior:'instant'})")
    record = page.evaluate_script(<<~JS)
      (() => {
        const region=document.querySelector("[data-image-upload-target='preview']");
        return {width:innerWidth,height:innerHeight,scroll_width:document.documentElement.scrollWidth,
          heading:region.querySelector("h2").textContent, bounds:region.getBoundingClientRect().toJSON(),
          image_bounds:[...region.querySelectorAll("img")].map(img=>img.getBoundingClientRect().toJSON()),
          active_id:document.activeElement.id, status:document.querySelector("#activity-image-status").textContent};
      })()
    JS
    expect(record["active_id"]).to eq(focus)
    expect(record["scroll_width"]).to be <= record["width"]
    expect(record["bounds"]["top"]).to be >= 0
    expect(record["bounds"]["bottom"]).to be <= record["height"]
    expect(record["image_bounds"].all? { |b| b["left"] >= 0 && b["right"] <= record["width"] }).to be(true)
    directory = Rails.root.join("tmp/activity-photo-preview-ui", ENV.fetch("ACTIVITY_PREVIEW_CAPTURE_LABEL", "local"))
    FileUtils.mkdir_p(directory)
    image_path = directory.join("#{mode}-#{width}.png")
    screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
    File.binwrite(image_path, Base64.strict_decode64(screenshot.fetch("data")))
    record.merge!(mode: mode, candidates: candidates, fields: fields, saved_image_count: @saved_images.length,
      screenshot: image_path.to_s, screenshot_sha256: Digest::SHA256.file(image_path).hexdigest,
      test_scrolled_for_inspection: true, focus_before_inspection_scroll: focus)
    File.write(directory.join("#{mode}-#{width}.json"), JSON.pretty_generate(record))
  end
end
