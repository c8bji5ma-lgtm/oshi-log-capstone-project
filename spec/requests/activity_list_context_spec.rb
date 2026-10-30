require "rails_helper"

RSpec.describe "Activity list context", type: :request do
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved) }
  let(:keyword) { "  日本語 +%2F &<記録>  " }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def activity_for(owner = user, **attributes)
    UserOshi.find_or_create_by!(user: owner, oshi: oshi)
    activity = build(:activity, :without_oshis, user: owner, occurred_on: "2025-05-10", **attributes)
    Activities::Save.call(activity: activity, oshi_ids: [ oshi.id ])
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def back_link
    document.css("a").find { |a| a.text == "活動記録一覧へ戻る" }["href"]
  end

  def query(path)
    Rack::Utils.parse_nested_query(URI.parse(path).query)
  end

  [ { year: "2025" }, { month: "2025-05" } ].each do |period|
    it "returns to the same #{period.keys.first} filters without transforming the keyword" do
      target = activity_for(title: "対象", memo: keyword)
      activity_for(create(:user), title: "非公開の記録", memo: keyword)
      filters = period.merge(oshi_id: oshi.id.to_s, activity_type: target.activity_type, q: keyword, through: "2025-05-20")
      get activities_path, params: filters
      expect(response).to have_http_status(:ok)
      detail = document.at_css(".activity-list a")["href"]
      expect(query(detail)).to eq("list_context" => filters.stringify_keys)
      expect(response.body).not_to include("非公開の記録")

      get detail
      expect(response).to have_http_status(:ok)
      back = back_link
      expect(query(back)).to eq(filters.stringify_keys)
      expect(document.css("a").find { |link| link.text == "編集" }["href"]).to eq(edit_activity_path(target, list_context: filters))
      expect(document.at_css("form[action='#{activity_path(target)}']")).to be_present
      get back
      expect(response).to have_http_status(:ok)
      expect(document.css(".activity-list a").map(&:text)).to eq([ "対象" ])
      expect(document.at_css("input[name='q']")["value"]).to eq(keyword)
    end
  end

  it "returns from a later page to the first page of the same filters" do
    51.times { |i| activity_for(title: "ページ対象#{i}") }
    filters = { month: "2025-05", q: "ページ対象" }
    get activities_path, params: filters
    older = document.css("a").find { |a| a.text == "さらに古い記録" }["href"]
    get older
    expect(document.css(".activity-list a").size).to eq(1)
    get document.at_css(".activity-list a")["href"]
    back = back_link
    expect(query(back)).to eq(filters.stringify_keys)
    get back
    expect(document.css(".activity-list a").size).to eq(50)
  end

  it "preserves the actual monthly drilldown including its through limit" do
    activity_for(title: "集計対象")
    get oshi_data_path, params: { year: "2025", oshi_id: oshi.id }
    drilldown = document.css(".data-bar-value a").find { |a| query(a["href"])["month"] == "2025-05" }["href"]
    filters = query(drilldown)
    expect(filters).to include("through" => "2025-12-31")
    get drilldown
    get document.at_css(".activity-list a")["href"]
    expect(query(back_link)).to eq(filters)
    get back_link
    expect(document.css(".activity-list a").map(&:text)).to eq([ "集計対象" ])
  end

  it "uses the normal list for unfiltered links and direct detail URLs" do
    target = activity_for(title: "直接の記録")
    get activities_path
    detail = document.at_css(".activity-list a")["href"]
    expect(detail).to eq(activity_path(target))
    get detail
    expect(back_link).to eq(activities_path)
    get activity_path(target), params: { q: "unrelated top-level input" }
    expect(back_link).to eq(activities_path)
  end

  it "preserves a whitespace-only keyword without stripping it" do
    activity_for(title: "空白の検索")
    get activities_path, params: { q: "  " }
    get document.at_css(".activity-list a")["href"]
    expect(query(back_link)).to eq("q" => "  ")
  end

  it "discards unknown keys and arbitrary URLs without losing allowed values" do
    target = activity_for(title: "対象")
    context = { q: "対象", cursor: "invalid", direction: "newer", return_to: "https://example.invalid/", user_id: [ "other" ] }
    get activity_path(target), params: { list_context: context, return_to: "//example.invalid/" }
    expect(response).to have_http_status(:ok)
    expect(URI.parse(back_link).path).to eq(activities_path)
    expect(query(back_link)).to eq("q" => "対象")
    get activity_path(target), params: { list_context: { return_to: "https://example.invalid/" } }
    expect(back_link).to eq(activities_path)
  end

  [ { year: "0000" }, { month: "2025-13" }, { year: "2025", month: "2025-05" },
    { through: "2025-02-30" }, { activity_type: "unknown" }, { oshi_id: "999999999999999999" } ].each do |context|
    it "keeps invalid scalar conditions for the existing list rejection: #{context.inspect}" do
      target = activity_for(title: "表示しない記録")
      get activity_path(target), params: { list_context: context }
      expect(response).to have_http_status(:ok)
      back = back_link
      expect(query(back)).to eq(context.stringify_keys)
      get edit_activity_path(target), params: { list_context: context }
      expect(response).to have_http_status(:ok)
      expect(query(detail_return_link)).to eq("list_context" => context.stringify_keys)
      get detail_return_link
      expect(query(back_link)).to eq(context.stringify_keys)
      get back_link
      expect(response).to have_http_status(:bad_request)
      expect(document.at_css("#activity-filter-errors[role='alert']")).to be_present
      expect(document.css(".activity-list a")).to be_empty
    end
  end

  [ "https://example.invalid/", [ "value" ], { q: [ "value" ] },
    { q: { nested: "value" } }, { q: 12 } ].each do |context|
    it "rejects malformed context structure or known value types: #{context.inspect}" do
      target = activity_for(title: "型エラーで表示しない記録")
      get activity_path(target), params: { list_context: context }, as: :json
      expect(response).to have_http_status(:bad_request)
      expect(response.body).to eq(Rails.public_path.join("400.html").read)
      expect(response.body).not_to include(target.title)
    end
  end

  it "keeps authentication and the owned detail scope" do
    foreign = activity_for(create(:user), title: "他人の非公開記録")
    get activity_path(foreign), params: { list_context: { q: "記録" } }
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(foreign.title)
    delete destroy_user_session_path
    get activity_path(foreign), params: { list_context: { q: "記録" } }
    expect(response).to redirect_to(new_user_session_path)
  end
  def edit_form_action
    document.at_css("form[data-activity-oshi-panel-target='activityForm']")["action"]
  end

  def detail_return_link
    document.css("a").find { |link| link.text == I18n.t("ui.activity.back_to_detail") }["href"]
  end

  def edit_submission(target, **changes)
    { title: target.title, oshi_ids: [ oshi.id.to_s ], lock_version: target.reload.lock_version.to_s,
      context_token: document.at_css("meta[name='activity-context-token']")["content"] }.merge(changes)
  end

  describe "edit round trips" do
    let(:filters) { { month: "2025-05", through: "2025-05-20", oshi_id: oshi.id.to_s, activity_type: "ライブ・イベント", q: keyword } }

    [ { year: "2025" }, { month: "2025-05" } ].each do |period|
      context "with #{period.keys.first} filters" do
        let(:filters) { period.merge(through: "2025-05-20", oshi_id: oshi.id.to_s, activity_type: "ライブ・イベント", q: keyword) }

        it "preserves the exact conditions through a successful update" do
          target = activity_for(title: "対象", memo: keyword, activity_type: "ライブ・イベント")
          get activities_path, params: filters
          get document.at_css(".activity-list a")["href"]
          get document.css("a").find { |link| link.text == "編集" }["href"]
          expect(query(edit_form_action)).to eq("list_context" => filters.stringify_keys)
          action = edit_form_action
          patch action, params: { activity: edit_submission(target, title: "編集後の対象") }
          expect(response).to have_http_status(:see_other)
          expect(response).to redirect_to(activity_path(target, list_context: filters))
          follow_redirect!
          expect(document.at_css("main h2").text).to eq("編集後の対象")
          expect(query(back_link)).to eq(filters.stringify_keys)
          get back_link
          expect(response).to have_http_status(:ok)
          expect(document.at_css("input[name='q']")["value"]).to eq(keyword)
          expect(document.css(".activity-list a").map(&:text)).to eq([ "編集後の対象" ])
          expect(target.reload.user_id).to eq(user.id)
        end

        it "preserves the exact conditions on cancel without saving" do
          target = activity_for(title: "取り消す対象", memo: keyword, activity_type: "ライブ・イベント")
          original = target.attributes
          get edit_activity_path(target), params: { list_context: filters }
          expect(query(edit_form_action)).to eq("list_context" => filters.stringify_keys)
          get detail_return_link
          expect(query(back_link)).to eq(filters.stringify_keys)
          get back_link
          expect(document.at_css("input[name='q']")["value"]).to eq(keyword)
          expect(target.reload.attributes).to eq(original)
        end
      end
    end

    [ nil, {} ].each do |context|
      it "keeps ordinary edit and update URLs for context #{context.inspect}" do
        target = activity_for(title: "直接編集")
        get edit_activity_path(target), params: { list_context: context }.compact
        expect(edit_form_action).to eq(activity_path(target))
        expect(detail_return_link).to eq(activity_path(target))
        patch edit_form_action, params: { activity: edit_submission(target, title: "直接編集後") }
        expect(response).to redirect_to(activity_path(target))
        follow_redirect!
        expect(back_link).to eq(activities_path)
      end
    end

    { validation: :unprocessable_content, conflict: :conflict, invalid_version: :bad_request }.each do |failure, status|
      it "keeps context, submitted values and recovery links after #{failure}" do
        target = activity_for(title: "保存済み", memo: keyword, activity_type: "ライブ・イベント")
        get edit_activity_path(target), params: { list_context: filters }
        action = edit_form_action
        changes = failure == :validation ? { title: "", amount: "123" } : { title: "手元の入力", amount: "123" }
        changes[:lock_version] = "invalid" if failure == :invalid_version
        submission = edit_submission(target, **changes)
        if failure == :conflict
          Activities::Save.call(activity: Activity.find(target.id), attributes: { title: "先行保存" },
            oshi_ids: [ oshi.id ], expected_lock_version: target.lock_version)
        end
        saved = target.reload.attributes
        patch action, params: { activity: submission }
        expect(response).to have_http_status(status)
        expect(query(edit_form_action)).to eq("list_context" => filters.stringify_keys)
        expect(query(detail_return_link)).to eq("list_context" => filters.stringify_keys)
        expect(document.at_css("#activity_title")["value"]).to eq(changes[:title])
        expect(document.at_css("#activity_amount")["value"]).to eq("123")
        expect(document.at_css("input[name='activity[lock_version]']")["value"]).to eq(submission[:lock_version])
        expect(target.reload.attributes).to eq(saved)
        if failure != :validation
          reload_link = document.at_css(".conflict-summary a")["href"]
          expect(reload_link).to eq(edit_activity_path(target, list_context: filters))
          get reload_link
          expect(query(edit_form_action)).to eq("list_context" => filters.stringify_keys)
          expect(document.at_css("input[name='activity[lock_version]']")["value"]).to eq(target.lock_version.to_s)
          get detail_return_link
        else
          action = edit_form_action
          patch action, params: { activity: edit_submission(target, title: "修正した入力") }
          expect(response).to redirect_to(activity_path(target, list_context: filters))
          follow_redirect!
        end
        expect(query(back_link)).to eq(filters.stringify_keys)
      end
    end

    it "does not clear a filter when the edited record no longer matches it" do
      target = activity_for(title: "対象の検索語")
      context = { q: "対象の検索語" }
      get edit_activity_path(target), params: { list_context: context }
      patch edit_form_action, params: { activity: edit_submission(target, title: "別のタイトル") }
      follow_redirect!
      get back_link
      expect(response).to have_http_status(:ok)
      expect(document.at_css("input[name='q']")["value"]).to eq("対象の検索語")
      expect(document.css(".activity-list a")).to be_empty
      expect(target.reload.title).to eq("別のタイトル")
    end

    it "discards unknown keys and arbitrary URLs throughout editing and saving" do
      target = activity_for(title: "対象")
      context = { q: "対象", return_to: "https://example.invalid/", cursor: "invalid",
        direction: "newer", user_id: [ "other" ], unknown: { nested: "value" } }
      get edit_activity_path(target), params: { list_context: context, return_to: "//example.invalid/" }
      expect(query(edit_form_action)).to eq("list_context" => { "q" => "対象" })
      expect(query(detail_return_link)).to eq("list_context" => { "q" => "対象" })
      patch activity_path(target), params: { list_context: context, return_to: "https://example.invalid/",
        activity: edit_submission(target, title: "対象 編集後") }
      expect(response).to redirect_to(activity_path(target, list_context: { q: "対象" }))
      follow_redirect!
      expect(query(back_link)).to eq("q" => "対象")
      expect(URI.parse(back_link).host).to be_nil
    end

    it "preserves a foreign oshi filter for the existing owned-list rejection" do
      target = activity_for(title: "本人の記録")
      foreign = create(:oshi, :approved)
      create(:user_oshi, user: create(:user), oshi: foreign)
      context = { oshi_id: foreign.id.to_s }
      get edit_activity_path(target), params: { list_context: context }
      patch edit_form_action, params: { activity: edit_submission(target, title: "本人の編集") }
      follow_redirect!
      expect(query(back_link)).to eq(context.stringify_keys)
      get back_link
      expect(response).to have_http_status(:bad_request)
      expect(document.css(".activity-list a")).to be_empty
      expect(target.reload.oshi_ids).to eq([ oshi.id ])
    end

    [ "https://example.invalid/", [ "value" ], { q: [ "value" ] },
      { q: { nested: "value" } }, { q: 12 } ].each do |context|
      [ :edit, :update ].each do |operation|
        it "rejects malformed #{operation} context #{context.inspect} without saving" do
          target = activity_for(title: "型エラーの記録")
          original = target.attributes
          if operation == :edit
            get edit_activity_path(target), params: { list_context: context }, as: :json
          else
            get edit_activity_path(target)
            patch activity_path(target), params: { list_context: context,
              activity: edit_submission(target, title: "保存しない") }, as: :json
          end
          expect(response).to have_http_status(:bad_request)
          expect(response.body).to eq(Rails.public_path.join("400.html").read)
          expect(response.body).not_to include(target.title)
          expect(target.reload.attributes).to eq(original)
        end
      end
    end

    it "keeps owned edit and update scope and login requirements" do
      own = activity_for(title: "本人")
      foreign = activity_for(create(:user), title: "非公開")
      original = foreign.attributes
      get edit_activity_path(own)
      input = edit_submission(own, title: "保存しない")
      get edit_activity_path(foreign), params: { list_context: filters }
      expect(response).to have_http_status(:not_found)
      patch activity_path(foreign), params: { list_context: filters, activity: input }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.attributes).to eq(original)
      delete destroy_user_session_path
      get edit_activity_path(own), params: { list_context: filters }
      expect(response).to redirect_to(new_user_session_path)
      patch activity_path(own), params: { list_context: filters, activity: input }
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
