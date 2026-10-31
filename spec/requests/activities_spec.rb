require "rails_helper"
require_relative "../support/activity_input_context"

RSpec.describe "Activities", type: :request do
  include ActivityInputContext
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let!(:oshi) { create(:oshi, :approved) }
  let!(:second_oshi) { create(:oshi, :rejected) }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second_oshi, ended_period: "2025")
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def activity_for(owner = user, oshis: [ oshi ], **attributes)
    oshis.each { |selected| UserOshi.find_or_create_by!(user: owner, oshi: selected) }
    activity = build(:activity, :without_oshis, user: owner, **attributes)
    Activities::Save.call(activity: activity, oshi_ids: oshis.map(&:id))
  end

  def input(**changes)
    { occurred_on: "2026-10-01", activity_type: "ライブ・イベント", title: "福岡公演", place: "福岡", memo: "感想", amount: "18400", oshi_ids: [ "", oshi.id.to_s ], context_token: (@activity_input_context ||= activity_form_context) }.merge(changes)
  end

  def versioned(activity, parameters)
    parameters.merge(lock_version: activity.lock_version.to_s)
  end

  def upload(filename = "image.png")
    fixture_file_upload(Rails.root.join("spec/fixtures/files", filename), filename == "invalid.txt" ? "text/plain" : "image/png")
  end

  def sized_upload(filename, size)
    type = { "image.png" => "image/png", "image.jpg" => "image/jpeg", "image.webp" => "image/webp" }.fetch(filename)
    tempfile = Tempfile.new([ "request-image-", File.extname(filename) ])
    tempfile.binmode
    tempfile.write(File.binread(Rails.root.join("spec/fixtures/files", filename)).ljust(size, "\0"))
    tempfile.rewind
    (@sized_uploads ||= []) << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, type, true, original_filename: filename)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def titles
    document.css(".activity-list a").map(&:text)
  end

  def expect_amount_guidance(invalid: false)
    field = document.at_css("input[name='activity[amount]']")
    expect(field).to be_present
    expect(document.css("[id='#{field['id']}']").size).to eq(1)
    expect(document.css("label[for='#{field['id']}']").map(&:text)).to eq([ "金額（円）" ])
    expect(field["aria-describedby"].to_s.split).to include("activity-amount-help")
    expect(document.css("#activity-amount-help").size).to eq(1)
    expect(document.at_css("#activity-amount-help").text).to eq("任意です。記録しない場合は空欄、0円として記録する場合は0を入力してください。")
    expect(field["aria-invalid"]).to eq(invalid.to_s)
    expect(field["required"]).to be_nil
    expect(field["min"]).to eq("0")
    expect(field["step"]).to eq("1")
    field
  end

  def expect_activity_preview
    region = document.at_css("[data-image-upload-target='preview']")
    expect(region).to be_present
    expect(region.key?("hidden")).to be(true)
    expect(region.at_css("h2").text).to eq("今回追加する画像（未保存）")
    expect(region.css("img")).to be_empty
    expect(region["aria-live"]).to be_nil
    expect(document.css("#activity-image-preview-heading").size).to eq(1)
    expect(document.at_css("#activity-image-status")["role"]).to eq("status")
  end

  describe "invalid activity parameter groups" do
    [ {}, { activity: nil }, { activity: {} }, { activity: "invalid" },
      { activity: [ "invalid" ] }, { activity: false } ].each do |parameters|
      it "returns 400 on create and update for #{parameters.inspect} without changing records or links" do
        activity = activity_for
        original = activity.attributes
        links = activity.activity_oshis.order(:id).pluck(:id, :oshi_id)
        counts = [ Activity.count, ActivityOshi.count ]

        post activities_path, params: parameters, as: :json
        expect(response).to have_http_status(:bad_request)
        expect([ Activity.count, ActivityOshi.count ]).to eq(counts)
        patch activity_path(activity), params: parameters, as: :json
        expect(response).to have_http_status(:bad_request)
        expect(activity.reload.attributes).to eq(original)
        expect(activity.activity_oshis.order(:id).pluck(:id, :oshi_id)).to eq(links)
        expect([ Activity.count, ActivityOshi.count ]).to eq(counts)
      end
    end
  end

  describe "index" do
    it "requires login" do
      delete destroy_user_session_path
      get activities_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "keeps a through-only bound and the clear action visible while preserving inclusive filtering" do
      included = activity_for(title: "上限日当日の記録", occurred_on: "2026-10-01")
      later = activity_for(title: "上限日より後の記録", occurred_on: "2026-10-02")
      get activities_path, params: { through: "2026-10-01" }

      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ included.title ])
      panel = document.at_css("details.activity-filter-panel")
      expect(panel.key?("open")).to be(false)
      expect(panel.at_css("form")["method"]).to eq("get")
      expect(document.at_css("#activity-filter-summary").parent.text).to include("対象日の上限: 2026-10-01（当日を含む）")
      clear = document.at_css(".activity-filter-status a[href='#{activities_path}']")
      expect(clear.text).to eq("条件を解除する")
      get clear["href"]
      expect(titles).to contain_exactly(included.title, later.title)
    end

    describe "empty states" do
      let(:first_activity_help) { "活動記録はまだありません。上の「記録する」から、最初の活動を残してみましょう。" }
      let(:no_results_help) { "条件に一致する活動記録はありません。検索条件を見直すか、「条件をクリア」で一覧に戻ってください。" }

      it "guides an empty owned history to the existing record action without counting other users" do
        activity_for(other_user, title: "他人の記録")

        get activities_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(first_activity_help)
        expect(response.body).not_to include(no_results_help, "他人の記録")
        expect(document.css("main a[href='#{new_activity_path}']").map(&:text)).to eq([ "記録する" ])
      end

      it "keeps first-record guidance for an empty history with valid search conditions" do
        get activities_path, params: { month: "2026-10", q: "ライブ" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(first_activity_help)
        expect(response.body).not_to include(no_results_help)
      end

      it "explains unmatched conditions and restores owned records through the existing clear action" do
        activity = activity_for(title: "登録済みの記録", occurred_on: "2026-10-01")
        filters = [
          { year: "2025" }, { month: "2026-09" }, { through: "2026-09-30" },
          { oshi_id: second_oshi.id }, { activity_type: "配信視聴" }, { q: "見つからない記録" }
        ]

        filters.each do |parameters|
          get activities_path, params: parameters

          expect(response).to have_http_status(:ok)
          expect(titles).to be_empty
          expect(response.body).to include(no_results_help)
          expect(response.body).not_to include(first_activity_help)
        end

        clear_link = document.at_css("form.activity-filter a[href='#{activities_path}']")
        expect(clear_link.text).to eq("条件をクリア")
        get clear_link["href"]

        expect(response).to have_http_status(:ok)
        expect(titles).to eq([ activity.title ])
        expect(response.body).not_to include(first_activity_help, no_results_help)
      end

      it "does not call an empty cursor page first use even when no records are owned" do
        activity_for(other_user, title: "他人の記録")
        page = Activities::KeysetPage.call(scope: other_user.activities, cursor: nil, direction: nil, purpose: "index")

        get activities_path, params: { cursor: page.older_cursor, direction: "older" }

        expect(response).to have_http_status(:ok)
        expect(titles).to be_empty
        expect(response.body).to include(no_results_help)
        expect(response.body).not_to include(first_activity_help, "他人の記録")
      end

      it "keeps invalid filters and page cursors as errors for an empty history" do
        [ { month: "bad" }, { q: [ "bad" ] }, { cursor: "invalid", direction: "older" } ].each do |parameters|
          get activities_path, params: parameters

          expect(response).to have_http_status(:bad_request)
          expect(document.at_css("#activity-filter-errors[role='alert']")).to be_present
          expect(titles).to be_empty
          expect(response.body).not_to include(first_activity_help, no_results_help)
        end
      end
    end

    it "lists only owned records grouped by month with stable descending order" do
      activity_for(title: "古い", occurred_on: "2026-09-30")
      activity_for(title: "同日早い", created_at: Time.utc(2026, 10, 1, 1))
      activity_for(title: "同日後1", created_at: Time.utc(2026, 10, 1, 2))
      activity_for(title: "同日後2", created_at: Time.utc(2026, 10, 1, 2))
      activity_for(other_user, title: "秘密", occurred_on: "2027-01-01")
      get activities_path
      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "同日後2", "同日後1", "同日早い", "古い" ])
      expect(document.css(".activity-month h2").map(&:text)).to eq([ "2026年10月", "2026年9月" ])
      expect(response.body).not_to include("秘密")
      expect(document.at_css("a[href='#{new_activity_path}']").text).to eq("記録する")
    end

    it "pages through every owned record by a stable keyset and returns to newer records" do
      timestamp = Time.utc(2026, 10, 1, 2)
      records = Array.new(52) { |index| activity_for(title: "ページ#{index}", created_at: timestamp) }
      activity_for(other_user, title: "秘密", created_at: timestamp + 1)

      get activities_path
      expect(response).to have_http_status(:ok)
      expect(titles).to eq(records.reverse.first(50).map(&:title))
      older = document.css("a").find { |link| link.text == "さらに古い記録" }["href"]
      expect(older).to include("cursor=", "direction=older")
      expect(response.body).not_to include("秘密")

      activity_for(title: "後から追加", created_at: timestamp + 2)
      get older
      expect(titles).to eq(records.first(2).reverse.map(&:title))
      expect(document.css("a").none? { |link| link.text == "さらに古い記録" }).to be(true)
      newer = document.css("a").find { |link| link.text == "新しい記録へ戻る" }["href"]

      get newer
      expect(titles).to eq(records.reverse.first(50).map(&:title))
      expect(titles).not_to include("後から追加")
      newest = document.css("a").find { |link| link.text == "新しい記録へ戻る" }["href"]
      get newest
      expect(titles).to eq([ "後から追加" ])
      expect(document.css("a").none? { |link| link.text == "新しい記録へ戻る" }).to be(true)
    end

    it "preserves filters across pages and resets the cursor when filters are submitted again" do
      Array.new(51) { |index| activity_for(title: "対象#{index}") }
      activity_for(title: "対象外", activity_type: "配信視聴")
      filters = { month: "2026-10", oshi_id: oshi.id.to_s, activity_type: "ライブ・イベント", q: "対象" }

      get activities_path, params: filters
      older = URI.parse(document.css("a").find { |link| link.text == "さらに古い記録" }["href"])
      query = Rack::Utils.parse_nested_query(older.query)
      expect(query.slice(*filters.keys.map(&:to_s))).to eq(filters.stringify_keys)
      expect(query).to include("cursor", "direction" => "older")
      expect(document.css("form.activity-filter input[name='cursor'], form.activity-filter input[name='direction']")).to be_empty

      get activities_path, params: filters
      expect(titles.size).to eq(50)
    end

    it "rejects malformed or cross-purpose page cursors without exposing records" do
      activity_for(title: "本人記録")
      get activities_path, params: { cursor: "invalid", direction: "older" }
      expect(response).to have_http_status(:bad_request)
      expect(titles).to be_empty
      expect(document.at_css("[role='alert']").text).to include("ページ情報が正しくありません")
    end

    it "combines month, oshi, category, and keyword filters without duplicates" do
      target = activity_for(title: "探す", oshis: [ oshi, second_oshi ], amount: 3200)
      activity_for(title: "別月", occurred_on: "2026-09-30")
      activity_for(title: "別推し", oshis: [ second_oshi ])
      activity_for(title: "探す別カテゴリ", activity_type: "配信視聴")
      get activities_path, params: { month: "2026-10", oshi_id: oshi.id.to_s, activity_type: target.activity_type, q: "探す" }
      expect(titles).to eq([ "探す" ])
      expect(response.body).to include("3,200円", "10/1", "ライブ・イベント")
    end

    [ :title, :place, :memo ].each do |field|
      it "searches #{field} with case-insensitive partial matches" do
        target = activity_for(**{ field => "Prefix-AbC-suffix" })
        activity_for(title: "無関係")
        get activities_path, params: { q: "aBc" }
        expect(titles).to eq([ target.title ])
      end
    end

    [ "%", "_", "\\" ].each do |character|
      it "escapes LIKE character #{character.inspect}" do
        target = activity_for(title: "特殊#{character}文字")
        activity_for(title: "特殊X文字")
        get activities_path, params: { q: character }
        expect(titles).to eq([ target.title ])
      end
    end

    it "does not search oshi names as keywords" do
      activity_for(title: "記録")
      get activities_path, params: { q: oshi.name }
      expect(titles).to be_empty
    end

    it "explains keyword search while preserving its label, example, and submitted value" do
      get activities_path, params: { q: "ライブ" }

      expect(response).to have_http_status(:ok)
      keyword = document.at_css("form.activity-filter input[name='q']")
      expect(document.at_css("label[for='#{keyword['id']}']").text).to eq("キーワード")
      expect(keyword["placeholder"]).to eq("例：ライブ、会場名")
      expect(keyword["value"]).to eq("ライブ")
      expect(keyword["aria-describedby"]).to eq("activity-keyword-help")
      expect(document.at_css("#activity-keyword-help").text).to eq("タイトル・場所・メモを検索します。推し名で探す場合は「推し」を選んでください。")
    end

    [ { month: "2026-13" }, { month: "0000-01" }, { month: "2026-1" }, { activity_type: "未知" }, { month: [ "2026-10" ] }, { q: { bad: "value" } }, { activity_type: [ "その他" ] }, { oshi_id: { bad: "id" } } ].each do |filters|
      it "renders a filter error with 400 for #{filters.inspect}" do
        activity_for(title: "本人記録")
        activity_for(other_user, title: "秘密")
        get activities_path, params: filters
        expect(response).to have_http_status(:bad_request)
        expect(document.at_css("#activity-filter-errors[role='alert']")).to be_present
        expect(document.at_css("details.activity-filter-panel").key?("open")).to be(true)
        expect(document.at_css("details.activity-filter-panel #activity-filter-errors")).to be_nil
        expect(document.css("form.activity-filter [aria-describedby~='activity-filter-errors']").size).to eq(4)
        expect(document.at_css("input[name='q']")["aria-describedby"].split).to contain_exactly("activity-keyword-help", "activity-filter-errors")
        expect(titles).to be_empty
        expect(response.body).not_to include("秘密")
      end
    end

    it "rejects an unregistered oshi filter" do
      unregistered = create(:oshi, :approved)
      get activities_path, params: { oshi_id: unregistered.id }
      expect(response).to have_http_status(:bad_request)
    end

    it "accepts empty filters and allows past rejected registered oshis" do
      activity_for(oshis: [ second_oshi ])
      get activities_path, params: { month: "", activity_type: "", q: "", oshi_id: second_oshi.id }
      expect(response).to have_http_status(:ok)
      expect(titles.size).to eq(1)
    end
  end

  describe "new and create" do
    it "shows only registered choices, fixed categories, and multiple upload inputs", :amount_guidance do
      unregistered = create(:oshi, :approved)
      get new_activity_path
      expect(response).to have_http_status(:ok)
      options = document.css("input[type='checkbox'][name='activity[oshi_ids][]']").map { |input| input["value"] }.reject(&:blank?)
      expect(options).to match_array([ oshi.id.to_s, second_oshi.id.to_s ])
      expect(options).not_to include(unregistered.id.to_s)
      expect(document.css("label.choice-chip[for^='activity_oshi_ids_']").map(&:text)).to contain_exactly(oshi.name, second_oshi.name)
      expect(document.at_css("input[type='file']")["multiple"]).to be_present
      expect(document.css("select[name='activity[activity_type]'] option").map(&:text)).to include(*Activity::ACTIVITY_TYPES)
      expect(document.at_css("input[name='activity[occurred_on]']")["value"]).to eq(Date.current.iso8601)
      expect_amount_guidance
      expect_activity_preview
    end

    it "preselects only an owned registered oshi from the first-record continuation" do
      get new_activity_path, params: { initial_oshi_id: second_oshi.id }
      expect(response).to have_http_status(:ok)
      selected = document.css("input[name='activity[oshi_ids][]'][checked]").map { |input| input["value"] }.reject(&:blank?)
      expect(selected).to eq([ second_oshi.id.to_s ])
    end

    it "rejects malformed, foreign and unregistered initial selections without leaking a selection" do
      foreign = create(:user_oshi, user: other_user).oshi
      unregistered = create(:oshi, :approved)
      [ "bad", foreign.id.to_s, unregistered.id.to_s, [ oshi.id.to_s ], { id: oshi.id.to_s } ].each do |value|
        get new_activity_path, params: { initial_oshi_id: value }
        expect(response).to have_http_status(:bad_request)
        expect(document.css("input[name='activity[oshi_ids][]'][checked]").map { |input| input["value"] }.reject(&:blank?)).to be_empty
        expect(document.at_css(".validation-errors").text).to include("選び直してください")
      end
    end

    it "guides a user with no registered oshis" do
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other_user.email, password: "password123" } }
      get new_activity_path
      expect(response.body).to include("先に推しを登録してください")
      expect(document.at_css("a[href='#{new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION)}']")).to be_present
      expect(document.at_css("form[action='#{activities_path}']")).to be_nil
      expect(document.at_css("#activity_title")).to be_nil
      expect(document.at_css("#activity_images")).to be_nil
    end


    it "keeps invalid initial selections as errors even when the user has no oshis" do
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other_user.email, password: "password123" } }
      [ "bad", oshi.id.to_s, [ oshi.id.to_s ] ].each do |value|
        get new_activity_path, params: { initial_oshi_id: value }

        expect(response).to have_http_status(:bad_request)
        expect(document.at_css(".validation-errors[role='alert']")).to be_present
        expect(document.at_css("#activity_title")).to be_present
        expect(document.css("input[name='activity[oshi_ids][]'][checked]")).to be_empty
      end
    end

    it "keeps submitted values and errors when a user without oshis posts an invalid activity" do
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other_user.email, password: "password123" } }

      expect {
        post activities_path, params: { activity: input(title: "入力を表示する記録", memo: "残すメモ", oshi_ids: [ "" ]) }
      }.not_to change(Activity, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css(".validation-errors[role='alert']")).to be_present
      expect(document.at_css("#activity_title")["value"]).to eq("入力を表示する記録")
      expect(document.at_css("#activity_memo").text.delete_prefix("\n")).to eq("残すメモ")
      expect(document.at_css("a[href='#{new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION)}']")).to be_present
    end

    it "creates for the current user, deduplicates ids, redirects and flashes" do
      post activities_path, params: { activity: input(user_id: other_user.id, oshi_ids: [ oshi.id.to_s, oshi.id.to_s ]) }
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(activities_path)
      activity = user.activities.last
      expect(activity.oshi_ids).to eq([ oshi.id ])
      expect(activity.amount).to eq(18400)
      expect(other_user.activities).to be_empty
      follow_redirect!
      expect(document.at_css("[role='status']").text).to eq("活動記録を登録しました。")
    end

    it "allows multiple registered oshis including rejected and past oshis" do
      post activities_path, params: { activity: input(oshi_ids: [ oshi.id.to_s, second_oshi.id.to_s ]) }
      expect(response).to redirect_to(activities_path)
      expect(user.activities.last.oshi_ids).to match_array([ oshi.id, second_oshi.id ])
    end

    it "allows a registered pending oshi and future dates" do
      pending_oshi = create(:oshi, :pending, created_by_user: user)
      create(:user_oshi, user: user, oshi: pending_oshi)
      post activities_path, params: { activity: input(oshi_ids: [ pending_oshi.id.to_s ], occurred_on: "2030-01-01") }
      expect(response).to redirect_to(activities_path)
    end

    [ [], [ "" ], nil ].each do |ids|
      it "rejects empty selection #{ids.inspect}" do
        expect { post activities_path, params: { activity: input(oshi_ids: ids) } }.not_to change(Activity, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("推しを1件以上選択してください")
      end
    end

    [ "bad", "0", "-1", "1foo", "1.0", " 1", { id: "1" }, [ "1" ] ].each do |id|
      it "rejects malformed id #{id.inspect}" do
        expect { post activities_path, params: { activity: input(oshi_ids: [ id ]) } }.not_to change(Activity, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "rejects an unexpected selection shape" do
      post activities_path, params: { activity: input(oshi_ids: { id: oshi.id }) }
      expect(response).to have_http_status(:unprocessable_content)
    end

    %i[approved pending rejected].each do |status|
      it "rejects unregistered #{status} oshis without silently retaining permitted ones" do
        forbidden = create(:oshi, status, created_by_user: other_user)
        create(:user_oshi, user: other_user, oshi: forbidden)
        expect { post activities_path, params: { activity: input(oshi_ids: [ oshi.id.to_s, forbidden.id.to_s ]) } }.not_to change(Activity, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("登録済みの推し")
      end
    end

    [ { title: "" }, { occurred_on: "2026-02-30" }, { activity_type: "不明" }, { amount: "-1" }, { amount: "1.5" }, { amount: "abc" } ].each do |changes|
      it "renders scalar validation errors for #{changes.inspect}", :amount_guidance do
        expect { post activities_path, params: { activity: input(**changes) } }.not_to change(Activity, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css(".validation-errors")).to be_present
        field = expect_amount_guidance(invalid: changes.key?(:amount))
        expect(field["value"]).to eq(changes[:amount]) if changes.key?(:amount) && changes[:amount] != "abc"
        expect(document.at_css("#activity_title")["value"]).to eq(input(**changes)[:title])
        expect(document.at_css("#activity_place")["value"]).to eq(input[:place])
        expect(document.at_css("#activity_memo").text.delete_prefix("\n")).to eq(input[:memo])
      end
    end

    it "does not replace an explicitly blank submitted date with today's default" do
      post activities_path, params: { activity: input(occurred_on: "") }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("input[name='activity[occurred_on]']")["value"].to_s).to eq("")
    end

    { "" => nil, "0" => 0 }.each do |value, expected|
      it "preserves amount #{value.inspect}", :amount_guidance do
        post activities_path, params: { activity: input(amount: value) }
        expect(user.activities.last.amount).to eq(expected)
        follow_redirect!
        expect(response.body).to include(expected.nil? ? "—" : "0円")
      end
    end

    it "creates multiple images" do
      post activities_path, params: { activity: input(images: [ upload, upload ]) }
      expect(response).to redirect_to(activities_path)
      expect(user.activities.last.images.count).to eq(2)
    end

    it "shows a recoverable Japanese error when new images total over 10 MiB" do
      files = [ sized_upload("image.png", 5.megabytes), sized_upload("image.webp", 5.megabytes + 1) ]

      expect do
        post activities_path, params: { activity: input(images: files) }
      end.not_to change(Activity, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors").text).to include("1回の送信合計を10 MiB以下", "分けて追加")
      expect(document.at_css("input[name='activity[title]']")["value"]).to eq(input[:title])
    end

    it "rolls back invalid images" do
      counts = [ Activity.count, ActivityOshi.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
      post activities_path, params: { activity: input(images: [ upload("invalid.txt") ]) }
      expect(response).to have_http_status(:unprocessable_content)
      expect([ Activity.count, ActivityOshi.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]).to eq(counts)
    end

    it "rejects arbitrary signed blob ids" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("not trusted"), filename: "secret.png", content_type: "image/png")
      post activities_path, params: { activity: input(images: [ blob.signed_id ]) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.activities).to be_empty
    end
  end

  describe "show and edit" do
    it "shows all fields, images, escaped memo, and CRUD navigation" do
      activity = activity_for(oshis: [ oshi, second_oshi ], title: "公演", place: "福岡", amount: 18400, memo: "1行目\n<script>secret()</script>")
      activity.images.attach([ upload, upload ])
      get activity_path(activity)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("2026/10/01", "ライブ・イベント", "公演", oshi.name, second_oshi.name, "福岡", "18,400円")
      expect(document.at_css(".activity-memo").text).to eq("1行目\n<script>secret()</script>")
      expect(document.css("main script")).to be_empty
      expect(document.css(".image-gallery img").map { |img| img["alt"] }).to eq([ "公演の画像 1", "公演の画像 2" ])
      expect(document.at_css("a[href='#{edit_activity_path(activity)}']")).to be_present
      form = document.at_css("form[action='#{activity_path(activity)}']")
      expect(form["data-turbo-confirm"]).to eq("この活動記録を削除しますか？")
      expect(form.at_css("input[name='_method']")["value"]).to eq("delete")
      expect(document.at_css("main a[href='#{activities_path}']")).to be_present
    end

    it "preselects existing oshis and shows persisted images in edit" do
      activity = activity_for(oshis: [ second_oshi ], title: "既存")
      activity.images.attach(upload)
      get edit_activity_path(activity)
      expect(response).to have_http_status(:ok)
      expect(document.css("input[name='activity[oshi_ids][]'][checked]").map { |input| input["value"] }.reject(&:blank?)).to eq([ second_oshi.id.to_s ])
      expect(document.at_css("input[name='activity[title]']")["value"]).to eq("既存")
      expect(document.at_css("input[name='activity[lock_version]']")["value"]).to eq(activity.lock_version.to_s)
      expect(document.css(".image-gallery img").size).to eq(1)
      expect(response.body).to include("新しく選択した画像は既存画像に追加されます")
      expect(document.css("input[type='checkbox'][name='activity[oshi_ids][]']").size).to eq(2)
      expect_activity_preview
    end

    [ :activity_path, :edit_activity_path ].each do |route|
      it "returns 404 for another user's #{route}" do
        get public_send(route, activity_for(other_user))
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "update" do
    it "keeps amount guidance and other submitted fields on edit errors", :amount_guidance do
      activity = activity_for(title: "保存済み", amount: 1250)
      get edit_activity_path(activity)
      expect(response).to have_http_status(:ok)
      expect(expect_amount_guidance["value"]).to eq("1250")

      %w[-1 1.5 abc].each do |amount|
        original = activity.reload.attributes
        patch activity_path(activity), params: { activity: versioned(activity, input(amount: amount, title: "訂正中")) }
        expect(response).to have_http_status(:unprocessable_content)
        field = expect_amount_guidance(invalid: true)
        expect(field["value"]).to eq(amount) unless amount == "abc"
        expect(document.at_css("#activity_title")["value"]).to eq("訂正中")
        expect(document.at_css("#activity_place")["value"]).to eq("福岡")
        expect(document.at_css("#activity_memo").text.delete_prefix("\n")).to eq("感想")
        expect(activity.reload.attributes).to eq(original)
        expect(activity.oshi_ids).to eq([ oshi.id ])
      end
    end

    it "updates scalars and selection, preserves owner, redirects to detail with notice" do
      activity = activity_for
      patch activity_path(activity), params: { activity: versioned(activity, input(title: "更新", amount: "0", user_id: other_user.id, oshi_ids: [ second_oshi.id.to_s ])) }
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(activity_path(activity))
      expect(activity.reload.title).to eq("更新")
      expect(activity.user_id).to eq(user.id)
      expect(activity.oshi_ids).to eq([ second_oshi.id ])
      follow_redirect!
      expect(document.at_css("[role='status']").text).to eq("活動記録を更新しました。")
    end

    it "changes one to multiple and multiple to one" do
      activity = activity_for
      patch activity_path(activity), params: { activity: versioned(activity, input(oshi_ids: [ oshi.id.to_s, second_oshi.id.to_s ])) }
      expect(activity.reload.oshi_ids).to match_array([ oshi.id, second_oshi.id ])
      patch activity_path(activity), params: { activity: versioned(activity, input(oshi_ids: [ oshi.id.to_s ])) }
      expect(activity.reload.oshi_ids).to eq([ oshi.id ])
    end

    it "rejects zero selection and keeps persisted values" do
      activity = activity_for(title: "元")
      patch activity_path(activity), params: { activity: versioned(activity, input(title: "失敗", oshi_ids: [])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(activity.reload.title).to eq("元")
      expect(activity.oshi_ids).to eq([ oshi.id ])
      expect(document.at_css("input[name='activity[lock_version]']")["value"]).to eq(activity.lock_version.to_s)
    end

    it "rejects forbidden ids and keeps persisted values" do
      activity = activity_for(title: "元")
      forbidden = create(:oshi)
      patch activity_path(activity), params: { activity: versioned(activity, input(oshi_ids: [ forbidden.id.to_s ])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(activity.reload.title).to eq("元")
      expect(activity.oshi_ids).to eq([ oshi.id ])
    end

    it "preserves images without an upload, then appends new images" do
      activity = activity_for
      activity.images.attach(upload)
      original = activity.images.first.blob_id
      patch activity_path(activity), params: { activity: versioned(activity, input(images: [ "" ])) }
      expect(activity.reload.images.map(&:blob_id)).to eq([ original ])
      patch activity_path(activity), params: { activity: versioned(activity, input(images: [ upload ])) }
      expect(activity.reload.images.count).to eq(2)
      expect(activity.images.map(&:blob_id)).to include(original)
    end

    it "rolls back invalid new images, scalar and oshi changes and only displays persisted images" do
      activity = activity_for(title: "元")
      activity.images.attach(upload)
      original = activity.images.first.blob_id
      counts = [ ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
      patch activity_path(activity), params: { activity: versioned(activity, input(title: "失敗", oshi_ids: [ second_oshi.id.to_s ], images: [ upload("invalid.txt") ])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".image-gallery img").size).to eq(1)
      expect(document.at_css("input[name='activity[title]']")["value"]).to eq("失敗")
      expect(activity.reload.title).to eq("元")
      expect(activity.oshi_ids).to eq([ oshi.id ])
      expect(activity.images.map(&:blob_id)).to eq([ original ])
      expect([ ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]).to eq(counts)
    end

    it "keeps persisted data when a scalar is invalid" do
      activity = activity_for(title: "元")
      patch activity_path(activity), params: { activity: versioned(activity, input(title: "", oshi_ids: [ second_oshi.id.to_s ])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(activity.reload.title).to eq("元")
      expect(activity.oshi_ids).to eq([ oshi.id ])
    end

    it "renders the submitted values and latest values with 409 when the edit version is stale" do
      activity = activity_for(title: "最初の内容")
      activity.images.attach(upload)
      stale_version = activity.reload.lock_version
      Activities::Save.call(activity: Activity.find(activity.id), attributes: { title: "先に保存した内容" },
        oshi_ids: [ second_oshi.id ], new_images: [ upload("image.jpg") ], expected_lock_version: stale_version)
      latest_blob_ids = activity.reload.images.map(&:blob_id)

      patch activity_path(activity), params: { activity: input(title: "古い画面の入力", amount: "999",
        oshi_ids: [ oshi.id.to_s ], images: [ upload("image.webp") ], lock_version: stale_version.to_s) }

      expect(response).to have_http_status(:conflict)
      expect(document.at_css("#activity_title")["value"]).to eq("古い画面の入力")
      expect(document.at_css("input[name='activity[lock_version]']")["value"]).to eq(stale_version.to_s)
      expect(document.at_css(".conflict-summary").text).to include("先に保存した内容", second_oshi.name)
      expect(document.at_css(".conflict-summary a")["href"]).to eq(edit_activity_path(activity))
      expect(document.at_css(".validation-errors").text).to include("別の画面で更新")
      expect(activity.reload).to have_attributes(title: "先に保存した内容")
      expect(activity.oshi_ids).to eq([ second_oshi.id ])
      expect(activity.images.map(&:blob_id)).to eq(latest_blob_ids)
    end

    [ nil, "", "1.0", "-1", "01", "2147483648" ].each do |invalid_version|
      it "returns 400 and does not save an invalid edit version #{invalid_version.inspect}" do
        activity = activity_for(title: "保存済み")
        original = activity.attributes
        patch activity_path(activity), params: { activity: input(title: "送信値", lock_version: invalid_version) }
        expect(response).to have_http_status(:bad_request)
        expect(document.at_css("#activity_title")["value"]).to eq("送信値")
        expect(document.at_css(".validation-errors").text).to include("編集情報が不正")
        expect(document.at_css(".conflict-summary a")["href"]).to eq(edit_activity_path(activity))
        expect(activity.reload.attributes).to eq(original)
      end
    end

    { json: "application/json", turbo_stream: "text/vnd.turbo-stream.html" }.each do |format, accept|
      [ :missing, "invalid" ].each do |invalid_version|
        it "renders HTML with 400 for a #{invalid_version} edit version requested as #{format}" do
          activity = activity_for(title: "保存済み")
          original = activity.attributes
          parameters = input(title: "送信値")
          parameters[:lock_version] = invalid_version unless invalid_version == :missing

          patch activity_path(activity), params: { activity: parameters }, headers: { "Accept" => accept }

          expect(response).to have_http_status(:bad_request)
          expect(response.media_type).to eq("text/html")
          expect(document.at_css("#activity_title")["value"]).to eq("送信値")
          expect(activity.reload.attributes).to eq(original)
        end
      end

      it "renders HTML with 409 and preserves the latest attributes, links and images when requested as #{format}" do
        activity = activity_for(title: "最初の内容")
        activity.images.attach(upload)
        stale_version = activity.reload.lock_version
        Activities::Save.call(activity: Activity.find(activity.id), attributes: { title: "先に保存した内容" },
          oshi_ids: [ second_oshi.id ], new_images: [ upload("image.jpg") ], expected_lock_version: stale_version)
        latest = activity.reload.attributes
        latest_oshi_ids = activity.oshi_ids
        latest_blob_ids = activity.images.map(&:blob_id)
        counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]

        patch activity_path(activity), params: { activity: input(title: "古い画面の入力",
          oshi_ids: [ oshi.id.to_s ], images: [ upload("image.webp") ], lock_version: stale_version.to_s) },
          headers: { "Accept" => accept }

        expect(response).to have_http_status(:conflict)
        expect(response.media_type).to eq("text/html")
        expect(document.at_css("#activity_title")["value"]).to eq("古い画面の入力")
        expect(document.at_css("input[name='activity[lock_version]']")["value"]).to eq(stale_version.to_s)
        expect(activity.reload.attributes).to eq(latest)
        expect(activity.oshi_ids).to eq(latest_oshi_ids)
        expect(activity.images.map(&:blob_id)).to eq(latest_blob_ids)
        expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      end

      it "renders HTML with 422 and rolls back attributes, links and images when requested as #{format}" do
        activity = activity_for(title: "保存済み")
        activity.images.attach(upload)
        activity.reload
        original = activity.attributes
        original_oshi_ids = activity.oshi_ids
        original_blob_ids = activity.images.map(&:blob_id)
        counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]

        patch activity_path(activity), params: { activity: versioned(activity, input(title: "",
          oshi_ids: [ second_oshi.id.to_s ], images: [ upload("image.webp") ])) }, headers: { "Accept" => accept }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.media_type).to eq("text/html")
        expect(activity.reload.attributes).to eq(original)
        expect(activity.oshi_ids).to eq(original_oshi_ids)
        expect(activity.images.map(&:blob_id)).to eq(original_blob_ids)
        expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      end
    end

    it "returns 404 for another user's activity" do
      activity = activity_for(other_user, title: "秘密")
      patch activity_path(activity), params: { activity: input }
      expect(response).to have_http_status(:not_found)
      expect(activity.reload.title).to eq("秘密")
    end
  end

  describe "destroy" do
    it "deletes the owned parent, all links and attachments, leaving oshis and other records" do
      activity = activity_for(oshis: [ oshi, second_oshi ])
      another = activity_for(other_user)
      activity.images.attach(upload)
      activity.update!(title: "版更新後の削除対象")
      expect(activity.lock_version).to be_positive
      attachment_id = activity.images.first.id
      delete activity_path(activity)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(activities_path)
      expect(Activity.exists?(activity.id)).to be(false)
      expect(ActivityOshi.where(activity_id: activity.id)).to be_empty
      expect(ActiveStorage::Attachment.exists?(attachment_id)).to be(false)
      expect(Activity.exists?(another.id)).to be(true)
      expect(user.user_oshis.count).to eq(2)
      expect(Oshi.where(id: [ oshi.id, second_oshi.id ]).count).to eq(2)
      follow_redirect!
      expect(document.at_css("[role='status']").text).to eq("活動記録を削除しました。")
    end

    it "rejects another user's deletion" do
      activity = activity_for(other_user)
      delete activity_path(activity)
      expect(response).to have_http_status(:not_found)
      expect(Activity.exists?(activity.id)).to be(true)
    end

    it "rolls back link deletion if destroying the parent fails" do
      activity = activity_for(oshis: [ oshi, second_oshi ])
      link_ids = activity.activity_oshis.pluck(:id)
      activity.images.attach(upload)
      attachment_id = activity.images.first.id
      allow_any_instance_of(Activity).to receive(:destroy!).and_wrap_original do |original|
        original.call
        raise ActiveRecord::RecordNotDestroyed
      end
      delete activity_path(activity)
      expect(response).to redirect_to(activity_path(activity))
      expect(Activity.exists?(activity.id)).to be(true)
      expect(activity.reload.activity_oshis.pluck(:id)).to match_array(link_ids)
      expect(ActiveStorage::Attachment.exists?(attachment_id)).to be(true)
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to eq("活動記録を削除できませんでした。")
    end
  end
end

RSpec.describe "Read-only guest activity empty states", type: :request do
  around do |example|
    previous = ENV["OSHI_GUEST_SANDBOX"]
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    example.run
  ensure
    previous.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous
  end

  it "does not invite an administrator guest with no records to create an activity" do
    create(:user, email: "demo@example.com")
    administrator = create(:user, :admin, email: "admin@example.com")
    %w[multi light empty].each { |name| create(:user, email: "#{name}@example.com") }
    expect(administrator.activities).to be_empty

    post guest_session_path(role: "admin")
    expect(response).to redirect_to(root_path)
    get activities_path

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.css(".activity-list")).to be_empty
    expect(response.body).to include("活動記録はまだありません。ゲストは閲覧専用のため、登録・変更・削除はできません。")
    expect(response.body).not_to include("最初の活動を残してみましょう", "上の「記録する」")
    expect(document.css("main a[href='#{new_activity_path}']").map(&:text)).to eq([ "記録する" ])

    expect {
      post activities_path, params: { activity: { title: "保存されないゲスト記録" } }
    }.not_to change(Activity, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "shows a read-only guest prerequisite message without inviting activity or oshi creation" do
    create(:user, email: "demo@example.com")
    create(:user, :admin, email: "admin@example.com")
    %w[multi light empty].each { |name| create(:user, email: "#{name}@example.com") }

    post guest_session_path(role: "admin")
    expect(response).to redirect_to(root_path)
    get new_activity_path

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(response.body).to include("ゲストは閲覧専用です。活動記録の登録はできません。")
    expect(document.at_css("form[action='#{activities_path}']")).to be_nil
    expect(document.css("main a[href^='#{new_oshi_path}']")).to be_empty
  end
end
