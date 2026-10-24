require "rails_helper"

RSpec.describe "Japanese calendar boundaries", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def document
    Nokogiri::HTML(response.body)
  end

  it "uses the Japanese date after midnight for recording, summaries and card memories" do
    travel_to(Time.utc(2026, 10, 23, 19, 10)) do
      expect(Time.zone.name).to eq("Tokyo")
      expect(Date.current).to eq(Date.new(2026, 10, 24))

      user = create(:user)
      oshi = create(:oshi, :approved)
      create(:user_oshi, user: user, oshi: oshi)
      today = create(:activity, user: user, occurred_on: Date.new(2026, 10, 24))
      tomorrow = create(:activity, user: user, occurred_on: Date.new(2026, 10, 25))
      post user_session_path, params: { user: { email: user.email, password: "password123" } }

      get new_activity_path
      expect(document.at_css("input[name='activity[occurred_on]']")["value"]).to eq("2026-10-24")

      get oshi_data_path
      expect(document.at_css("#activity-count").text).to eq("1回")
      current_month = document.at_css("a[aria-label='2026年10月の活動1件を見る']")
      expect(Rack::Utils.parse_nested_query(URI.parse(current_month["href"]).query)["through"]).to eq("2026-10-24")

      get memories_card_path
      ids = response.parsed_body.fetch("activities").map { |activity| activity.fetch("id") }
      expect(ids).to include(today.id.to_s)
      expect(ids).not_to include(tomorrow.id.to_s)
    end
  end

  [
    [ Time.utc(2026, 12, 31, 14, 59, 59), Date.new(2026, 12, 31) ],
    [ Time.utc(2026, 12, 31, 15), Date.new(2027, 1, 1) ]
  ].each do |instant, japanese_date|
    it "switches home and card years at Japanese New Year for #{instant.iso8601}" do
      travel_to(instant) do
        user = create(:user)
        december = create(:activity, user: user, title: "12月の記録", occurred_on: Date.new(2026, 12, 31))
        january = create(:activity, user: user, title: "1月の記録", occurred_on: Date.new(2027, 1, 1))
        post user_session_path, params: { user: { email: user.email, password: "password123" } }

        expect(Date.current).to eq(japanese_date)
        get home_path
        expect(document.at_css(".home-eyebrow").text).to include(japanese_date.strftime("%Y年%-m月"))
        expect(document.at_css(".home-summary-card").text).to include("活動回数", "1回")

        get statistics_card_path
        expect(response.parsed_body.fetch("year")).to eq(japanese_date.year.to_s)

        get memories_card_path
        ids = response.parsed_body.fetch("activities").map { |activity| activity.fetch("id") }
        expected_ids = japanese_date.year == 2026 ? [ december.id.to_s ] : [ january.id.to_s, december.id.to_s ]
        expect(ids).to eq(expected_ids)
      end
    end
  end
end
