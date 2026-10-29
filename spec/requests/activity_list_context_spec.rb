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
      expect(document.at_css("a[href='#{edit_activity_path(target)}']")).to be_present
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
      get back
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
end
