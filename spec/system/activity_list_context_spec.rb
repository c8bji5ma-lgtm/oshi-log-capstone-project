require "rails_helper"
require "vips"
require "digest"
require "tmpdir"
require "json"
require "base64"
require "active_storage/service/disk_service"

RSpec.describe "Activity list return navigation", type: :system do
  [ 375, 1280 ].each do |width|
    it "keeps each tab's filters and keyboard return at #{width}px" do
      user = create(:user)
      oshi = create(:oshi, :approved)
      create(:user_oshi, user: user, oshi: oshi)
      keyword = "  日本語 +%2F &<記録>  "
      first = build(:activity, :without_oshis, user: user, title: "観測対象A", occurred_on: "2025-05-10", memo: keyword)
      second = build(:activity, :without_oshis, user: user, title: "観測対象B", occurred_on: "2025-05-11", memo: "変更後 B")
      [ first, second ].each { |activity| Activities::Save.call(activity: activity, oshi_ids: [ oshi.id ]) }
      originals = [ first, second ].map(&:attributes)
      page.current_window.resize_to(width, 900)
      visit new_user_session_path
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
      expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
      filters = { month: "2025-05", oshi_id: oshi.id, activity_type: first.activity_type, q: keyword, through: "2025-05-20" }
      visit activities_path(filters)
      expect(page).to have_link("観測対象A")
      expect(page).not_to have_link("観測対象B")
      find(".activity-list a", text: "観測対象A").send_keys(:enter)
      expect(page).to have_css("main h1", exact_text: "活動記録の詳細")
      first_detail_url = page.current_url
      capture_context(width, "detail")
      find_link("活動記録一覧へ戻る").send_keys(:enter)
      open_activity_filters
      expect(page).to have_field("q", with: keyword)
      expect(page).to have_select("oshi_id", selected: oshi.name)
      expect(page).to have_field("month", with: "2025-05")
      expect(find("input[name='through']", visible: :all).value).to eq("2025-05-20")
      expect(page).to have_link("観測対象A")
      expect(page).not_to have_link("観測対象B")
      capture_context(width, "returned")

      fill_in "q", with: "変更後 B"
      find("form.activity-filter input[type='submit']").click
      expect(page).to have_link("観測対象B")
      expect(page).not_to have_link("観測対象A")
      click_link "観測対象B"
      expect(page).to have_css("main h2", exact_text: "観測対象B")
      second_window = open_new_window
      within_window(second_window) do
        visit first_detail_url
        expect(page).to have_css("main h2", exact_text: "観測対象A")
        click_link "活動記録一覧へ戻る"
        open_activity_filters
        expect(page).to have_field("q", with: keyword)
        expect(page).to have_link("観測対象A")
        expect(page).not_to have_link("観測対象B")
      end
      second_window.close
      click_link "活動記録一覧へ戻る"
      open_activity_filters
      expect(page).to have_field("q", with: "変更後 B")
      expect(page).to have_link("観測対象B")
      expect(page).not_to have_link("観測対象A")

      visit activity_path(first)
      click_link "活動記録一覧へ戻る"
      open_activity_filters
      expect(page).to have_field("q", with: "")
      expect(page).to have_link("観測対象A")
      expect(page).to have_link("観測対象B")
      expect([ first, second ].map { |activity| activity.reload.attributes }).to eq(originals)
    end
  end


  [ 375, 1280 ].each do |width|
    it "preserves edit, cancel, validation and saved filters independently in tabs at #{width}px" do
      user = create(:user)
      oshi = create(:oshi, :approved)
      create(:user_oshi, user: user, oshi: oshi)
      keyword = "  日本語 +%2F &<記録>  "
      first = build(:activity, :without_oshis, user: user, title: "編集対象A", occurred_on: "2025-05-10", memo: keyword)
      second = build(:activity, :without_oshis, user: user, title: "編集対象B", occurred_on: "2025-05-11", memo: "変更後 B")
      [ first, second ].each { |activity| Activities::Save.call(activity: activity, oshi_ids: [ oshi.id ]) }
      original_first = first.attributes
      period = width == 375 ? { year: "2025" } : { month: "2025-05" }
      filters = period.merge(oshi_id: oshi.id.to_s, activity_type: first.activity_type, q: keyword, through: "2025-05-20")
      page.current_window.resize_to(width, 900)
      visit new_user_session_path
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password123"
      click_button "ログイン"
      expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
      visit activities_path(filters)
      click_link "編集対象A"
      click_link "編集", exact: true
      expect(page).to have_field("activity_title", with: "編集対象A")
      original_edit_url = page.current_url
      expect(edit_filter_query).to eq("list_context" => filters.stringify_keys)
      fill_in "activity_title", with: "保存しない入力"
      expect(page.evaluate_script("document.activeElement.id")).to eq("activity_title")
      capture_context(width, "edit-cancel")
      expect(page.evaluate_script("document.activeElement.id")).to eq("activity_title")
      click_link I18n.t("ui.activity.back_to_detail")
      expect(page).to have_css("main h2", exact_text: "編集対象A")
      click_link "活動記録一覧へ戻る"
      open_activity_filters
      expect(page).to have_field("q", with: keyword)
      expect(returned_filter_query).to eq(filters.stringify_keys)
      expect(first.reload.attributes).to eq(original_first)
      capture_context(width, "edit-cancel-returned")

      fill_in "q", with: "変更後 B"
      find("form.activity-filter input[type='submit']").click
      expect(page).to have_link("編集対象B")
      expect(page).not_to have_link("編集対象A")
      second_filters = filters.merge(q: "変更後 B")
      click_link "編集対象B"
      click_link "編集", exact: true
      expect(page).to have_field("activity_title", with: "編集対象B")
      expect(edit_filter_query).to eq("list_context" => second_filters.stringify_keys)
      original_window = current_window
      second_window = open_new_window
      within_window(second_window) do
        visit original_edit_url
        expect(page).to have_field("activity_title", with: "編集対象A")
        expect(edit_filter_query).to eq("list_context" => filters.stringify_keys)
      end
      switch_to_window(original_window)

      fill_in "activity_title", with: ""
      page.execute_script("document.querySelector('#activity_title').required=false")
      find("form[data-activity-oshi-panel-target='activityForm'] input[type='submit']").click
      expect(page).to have_css(".validation-errors")
      expect(page).to have_field("activity_title", with: "")
      expect(edit_filter_query).to eq("list_context" => second_filters.stringify_keys)
      expect(second.reload.title).to eq("編集対象B")
      capture_context(width, "edit-422")
      fill_in "activity_title", with: "編集対象B 更新後"
      find("form[data-activity-oshi-panel-target='activityForm'] input[type='submit']").click
      expect(page).to have_css("main h2", exact_text: "編集対象B 更新後")
      expect(Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)).to eq("list_context" => second_filters.stringify_keys)
      capture_context(width, "edit-saved-detail")
      click_link "活動記録一覧へ戻る"
      open_activity_filters
      expect(page).to have_field("q", with: "変更後 B")
      expect(returned_filter_query).to eq(second_filters.stringify_keys)
      expect(page).to have_link("編集対象B 更新後")
      expect(page).not_to have_link("編集対象A")
      capture_context(width, "edit-saved-returned")

      within_window(second_window) do
        click_link I18n.t("ui.activity.back_to_detail")
        expect(page).to have_css("main h2", exact_text: "編集対象A")
        click_link "活動記録一覧へ戻る"
        open_activity_filters
        expect(page).to have_field("q", with: keyword)
        expect(returned_filter_query).to eq(filters.stringify_keys)
        expect(page).to have_link("編集対象A")
        expect(page).not_to have_link("編集対象B 更新後")
        capture_context(width, "edit-other-tab-returned")
      end
      second_window.close
      open_activity_filters
      expect(page).to have_field("q", with: "変更後 B")
      expect(first.reload.attributes).to eq(original_first)
      expect(second.reload).to have_attributes(title: "編集対象B 更新後", memo: "変更後 B", user_id: user.id)

      visit edit_activity_path(first)
      expect(page).to have_field("activity_title", with: "編集対象A")
      expect(edit_filter_query).to eq({})
      click_link I18n.t("ui.activity.back_to_detail")
      click_link "活動記録一覧へ戻る"
      open_activity_filters
      expect(page).to have_field("q", with: "")
      expect(page).to have_link("編集対象A")
      expect(page).to have_link("編集対象B 更新後")
    end
  end


  context "with inline oshi registration and selected photos" do
    include_context "emotion master data"

    let(:user) { create(:user) }
    let(:personal) { create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "条件保持する推し")) }
    let(:candidate) { create(:oshi, :approved, name: "画面内で追加する推し") }

    around do |example|
      Dir.mktmpdir("h01-context-photos-", Rails.root.join("tmp")) do |directory|
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

    # Reuse the H04/UX07 helper bodies and synthetic image cases without changing their original specs.
    def image_file(name, width, height, color)
      path = @directory.join(name)
      Vips::Image.black(width, height, bands: 3).new_from_image(color).copy(interpretation: :srgb).write_to_file(path.to_s, compression: 9, strip: true)
      path
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

    def search(query)
      within("#activity-oshi-panel") do
        fill_in "推しを検索", with: query
        click_button "検索", exact: true
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


    def expect_continuity_preserved
      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => {
          const original=window.contextIntegration;
          return original.form===document.querySelector("[data-activity-oshi-panel-target=activityForm]") &&
            original.contextInput===document.querySelector("#activity_context_token") &&
            original.contextValue===original.contextInput.value &&
            original.metaValue===document.querySelector("meta[name=activity-context-token]").content &&
            original.panelController===window.Stimulus.getControllerForElementAndIdentifier(
              original.form.closest("[data-controller~=activity-oshi-panel]"),"activity-oshi-panel") &&
            original.checked.every(id=>document.getElementById(id)?.checked);
        })()
      JS
    end

    [ 375, 1280 ].each do |width|
      it "keeps filtered editing, inline oshi selection and actual photo bytes together at #{width}px" do
        personal
        added = candidate
        keyword = "  日本語 +%2F &<記録>  "
        @activity = build(:activity, :without_oshis, user: user, title: "写真と推しを追加する活動",
          occurred_on: "2025-05-10", activity_type: "ライブ・イベント", memo: keyword)
        Activities::Save.call(activity: @activity, oshi_ids: [ personal.oshi_id ])
        @activity.images.attach(io: File.open(@saved, "rb"), filename: "saved-red.png", content_type: "image/png")
        saved_blob_ids = @activity.reload.images.map(&:blob_id)
        period = width == 375 ? { year: "2025" } : { month: "2025-05" }
        filters = period.merge(through: "2025-05-20", oshi_id: personal.oshi_id.to_s,
          activity_type: @activity.activity_type, q: keyword)
        page.current_window.resize_to(width, 900)
        visit new_user_session_path
        fill_in "user_email", with: user.email
        fill_in "user_password", with: "password123"
        click_button "ログイン"
        expect(page).to have_css("main h1", exact_text: "ホーム")
        visit activities_path(filters)
        click_link "写真と推しを追加する活動"
        expect(page).to have_css("main h1", exact_text: "活動記録の詳細")
        expect(returned_filter_query).to eq("list_context" => filters.stringify_keys)
        click_link "編集", exact: true
        expect(page).to have_field("activity_title", with: @activity.title)
        expect(edit_filter_query).to eq("list_context" => filters.stringify_keys)
        expect(returned_filter_query).to eq("list_context" => filters.stringify_keys)
        fill_in "activity_title", with: "写真と推しを追加した活動"
        fill_in "activity_place", with: "保持する会場"
        fill_in "activity_memo", with: keyword + "\n保持するメモ"
        fill_in "activity_amount", with: "0"
        fill_in "活動日（必須）", with: Date.new(2025, 5, 12)
        check "感動", allow_label_click: true
        @fields = fields
        @saved_images = page.evaluate_script("Array.from(document.querySelectorAll('main form section:not([data-image-upload-target]) img')).map(img=>img.getAttribute('src'))")
        install_url_monitor
        @activity_count = Activity.count
        @image_counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
        attach_file "activity_images", [ @large, @small ]
        expect(page).to have_css("#activity_images[data-image-upload-ready='true']", wait: 20)
        selected = expect_preview_matches(2)
        expect(selected.first).to include("width" => 2560, "height" => 1706)
        @files = file_info
        expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(@image_counts)
        page.execute_script(<<~JS)
          const input=document.querySelector("#activity_images");
          window.originalActivityForm=input.form;
          window.originalActivityInput=input;
          window.originalActivityFiles=input.files;
          window.originalImageController=window.Stimulus.getControllerForElementAndIdentifier(
            input.closest("[data-controller~='image-upload']"),"image-upload");
          window.originalPreviewURLs=[...document.querySelectorAll("[data-image-upload-target='previewImages'] img")].map(img=>img.src);
          window.contextIntegration={
            form:input.form,contextInput:document.querySelector("#activity_context_token"),
            contextValue:document.querySelector("#activity_context_token").value,
            metaValue:document.querySelector("meta[name=activity-context-token]").content,
            panelController:window.Stimulus.getControllerForElementAndIdentifier(
              input.form.closest("[data-controller~=activity-oshi-panel]"),"activity-oshi-panel"),
            checked:[...document.querySelectorAll("input[name='activity[oshi_ids][]']:checked")].map(input=>input.id)
          };
        JS
        allow(Activities::Save).to receive(:call).and_call_original
        open_panel
        add_existing(added)
        expect_preserved
        expect_continuity_preserved
        expect(expect_preview_matches(2)).to eq(selected)
        expect(page).to have_checked_field(personal.oshi.name, type: "checkbox", visible: :all)
        expect(@activity.reload.oshi_ids).to eq([ personal.oshi_id ])
        expect(Activities::Save).not_to have_received(:call)
        expect(edit_filter_query).to eq("list_context" => filters.stringify_keys)
        capture_context(width, "integrated-panel")

        click_button I18n.t("ui.activity_panel.close")
        expect_preserved
        expect_continuity_preserved
        expect(expect_preview_matches(2)).to eq(selected)
        expect(page.evaluate_script("document.activeElement===document.querySelector('[data-activity-oshi-panel-target=openButton]')")).to be(true)
        capture_context(width, "integrated-photos")
        directory = Rails.root.join("tmp/h01-ui", ENV.fetch("H01_CAPTURE_LABEL", "initial"))
        File.write(directory.join("#{width}-integrated-files.json"), JSON.pretty_generate(
          fields: fields, selected_files: selected, preview_files: file_details(previews: true),
          form_DOM_FileList_controllers_URLs_and_continuity_preserved: true,
          live_object_URLs: live_urls.size, blob_count_before_update: @image_counts.first,
          attachment_count_before_update: @image_counts.last, activity_save_calls_before_update: 0,
          original_selection_ids: [ personal.oshi_id ], additional_selection_id: added.id,
          query: edit_filter_query))

        within("[data-activity-oshi-panel-target='activityForm']") { click_button "更新する" }
        expect(page).to have_css("main h2", exact_text: "写真と推しを追加した活動")
        expect(page).to have_css("[role='status']", text: "活動記録を更新しました。")
        expect(Activities::Save).to have_received(:call).once
        expect(returned_filter_query).to eq("list_context" => filters.stringify_keys)
        expect(URI.parse(page.current_url).path).to eq(activity_path(@activity))
        expect(Activity.count).to eq(@activity_count)
        saved = @activity.reload
        expect(saved).to have_attributes(user_id: user.id, title: "写真と推しを追加した活動",
          occurred_on: Date.new(2025, 5, 12), amount: 0, place: "保持する会場", memo: keyword + "\r\n保持するメモ")
        expect(saved.oshi_ids).to match_array([ personal.oshi_id, added.id ])
        expect(saved.emotions.pluck(:name)).to eq([ "感動" ])
        expect(saved.images.size).to eq(3)
        expect(saved.images.map(&:blob_id)).to include(*saved_blob_ids)
        original_blob = saved.images.find { |attachment| saved_blob_ids.include?(attachment.blob_id) }.blob
        expect(Digest::SHA256.hexdigest(original_blob.download)).to eq(Digest::SHA256.file(@saved).hexdigest)
        uploaded = saved.images.reject { |attachment| saved_blob_ids.include?(attachment.blob_id) }.map(&:blob)
        actual_files = uploaded.map do |blob|
          { "name" => blob.filename.to_s, "bytes" => blob.byte_size, "type" => blob.content_type,
            "sha256" => Digest::SHA256.hexdigest(blob.download) }
        end
        expect(actual_files).to match_array(selected.map { |file| file.slice("name", "bytes", "type", "sha256") })
        capture_context(width, "integrated-saved-detail")
        click_link "活動記録一覧へ戻る"
        open_activity_filters
        expect(page).to have_field("q", with: keyword)
        expect(returned_filter_query).to eq(filters.stringify_keys)
        expect(page).to have_select("oshi_id", selected: personal.oshi.name)
        expect(page).to have_link("写真と推しを追加した活動")
        capture_context(width, "integrated-returned")
        File.write(directory.join("#{width}-integrated-saved.json"), JSON.pretty_generate(
          saved_files: actual_files, original_saved_blob_ids: saved_blob_ids, saved_oshi_ids: saved.oshi_ids,
          saved_lock_version: saved.lock_version, activity_save_calls: 1,
          original_photo_bytes_preserved: true, query: returned_filter_query))
      end
    end
  end

  def open_activity_filters
    expect(page).to have_current_path(activities_path, ignore_query: true)
    expect(page).to have_css("main h1", text: "活動記録一覧", exact_text: true)
    expect(page).to have_no_css("html[data-turbo-preview], html[aria-busy='true']")
    panel = find(".activity-filter-panel")
    panel.find("summary").click unless panel.matches_css?("[open]", wait: 0)
    expect(page).to have_css("form.activity-filter")
  end

  def edit_filter_query
    Rack::Utils.parse_nested_query(URI.parse(find("form[data-activity-oshi-panel-target='activityForm']")[:action]).query)
  end

  def returned_filter_query
    Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
  end

  def capture_context(width, phase)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    browser = page.driver.browser
    size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    shot = browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
    directory = Rails.root.join("tmp/h01-ui", ENV.fetch("H01_CAPTURE_LABEL", "initial"))
    FileUtils.mkdir_p(directory)
    path = directory.join("#{width}-#{phase}.png")
    File.binwrite(path, Base64.strict_decode64(shot.fetch("data")))
    record = {
      query: Rack::Utils.parse_nested_query(URI.parse(page.current_url).query),
      back_href: page.has_link?("活動記録一覧へ戻る", wait: 0) ? find_link("活動記録一覧へ戻る")[:href] : nil,
      keyword: page.has_css?("input[name='q']", wait: 0) ? find("input[name='q']").value : nil,
      viewport_width: page.evaluate_script("innerWidth"),
      scroll_width: page.evaluate_script("document.documentElement.scrollWidth"),
      screenshot: path.to_s,
      active_id: page.evaluate_script("document.activeElement.id"),
      edit_form_query: page.has_css?("form[data-activity-oshi-panel-target='activityForm']", wait: 0) ? edit_filter_query : nil
    }
    File.write(directory.join("#{width}-#{phase}.json"), JSON.pretty_generate(record))
  end
end
