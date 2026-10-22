require "rails_helper"

RSpec.describe "Activity summary drilldowns", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "推しA") }
  let(:second_oshi) { create(:oshi, :approved, name: "推しB") }

  around { |example| travel_to(Date.new(2026, 10, 6)) { example.run } }

  def document
    Nokogiri::HTML(response.body)
  end

  def record(title:, occurred_on:, oshis: [ oshi ], activity_type: "ライブ・イベント")
    activity = build(:activity, :without_oshis, user: user, title: title, occurred_on: occurred_on, activity_type: activity_type)
    Activities::Save.call(activity: activity, oshi_ids: oshis.map(&:id))
  end

  before do
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second_oshi)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  it "links monthly, category and oshi totals to the exact owned activity set through today" do
    record(title: "対象", occurred_on: Date.new(2026, 10, 1), oshis: [ oshi, second_oshi ])
    record(title: "別カテゴリ", occurred_on: Date.new(2026, 9, 1), activity_type: "配信視聴")
    record(title: "未来", occurred_on: Date.new(2026, 10, 7))
    other = create(:user)
    foreign_oshi = create(:oshi, :approved)
    create(:user_oshi, user: other, oshi: foreign_oshi)
    foreign = build(:activity, :without_oshis, user: other, title: "他人", occurred_on: Date.new(2026, 10, 1))
    Activities::Save.call(activity: foreign, oshi_ids: [ foreign_oshi.id ])

    get oshi_data_path
    expect(response).to have_http_status(:ok)
    october = document.at_css("a[aria-label='2026年10月の活動1件を見る']")
    expect(october).to be_present
    get october["href"]
    expect(document.css(".activity-list h3").map(&:text)).to eq([ "対象" ])
    expect(document.at_css("#activity-filter-summary").text).to include("適用中の条件")
    expect(document.at_css("a", text: "推し活データへ戻る")).to be_present

    get oshi_data_path
    category = document.at_css("a[aria-label='2026年のライブ・イベントの活動1件を見る']")
    get category["href"]
    expect(document.css(".activity-list h3").map(&:text)).to eq([ "対象" ])

    get oshi_data_path
    per_oshi = document.at_css("a[aria-label='2026年の推しAの活動2件を見る']")
    get per_oshi["href"]
    expect(document.css(".activity-list h3").map(&:text)).to eq([ "対象", "別カテゴリ" ])
    expect(response.body).not_to include("未来", "他人")
  end

  it "rejects malformed boundaries and conflicting year/month without exposing records" do
    record(title: "秘密にしない本人記録", occurred_on: Date.new(2026, 10, 1))
    [ { through: "bad" }, { through: "2026-1-1" }, { through: [ "2026-10-06" ] }, { through: { bad: "2026-10-06" } }, { year: "2026", month: "2026-10" } ].each do |filters|
      get activities_path, params: filters
      expect(response).to have_http_status(:bad_request)
      expect(document.css(".activity-list")).to be_empty
      expect(document.at_css("[role='alert']")).to be_present
    end
  end

  it "does not add activity drilldowns to fixed costs" do
    create(:subscription, user: user, amount: 1000)
    get oshi_data_path
    fixed = document.at_css("[aria-labelledby='fixed-cost-heading']")
    expect(fixed.css("a").map(&:text)).to eq([ "固定費を管理する" ])
    expect(fixed.text).to include("活動支出には含めず")
  end

it "uses the summary period end for current and past year links" do
  record(title: "昨年", occurred_on: Date.new(2025, 12, 31))
  get oshi_data_path, params: { year: "2025", oshi_id: oshi.id }
  past = URI.parse(document.at_css("a[aria-label='2025年12月の活動1件を見る']")["href"])
  expect(Rack::Utils.parse_nested_query(past.query)).to include("through" => "2025-12-31", "oshi_id" => oshi.id.to_s)

  get oshi_data_path
  current = URI.parse(document.at_css("a[aria-label='2026年10月の活動0件を見る']")["href"])
  expect(Rack::Utils.parse_nested_query(current.query)["through"]).to eq(Date.current.iso8601)
end
end
