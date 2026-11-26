require "rails_helper"

RSpec.describe "Activity entry from a personal oshi", type: :request do
  let(:user) { create(:user) }
  let!(:record) { create(:user_oshi, user: user) }
  let!(:other) { create(:user_oshi, user: user) }

  before { post user_session_path, params: { user: { email: user.email, password: "password123" } } }

  def document
    Nokogiri::HTML(response.body)
  end

  def activity_for(oshis, date, owner: user)
    build(:activity, :without_oshis, user: owner, occurred_on: date).tap do |activity|
      oshis.each { |oshi| activity.activity_oshis.build(oshi: oshi) }
      activity.save!
    end
  end

  it "opens the editable activity form with the matching master oshi selected" do
    get user_oshi_path(record)
    link = document.at_css("a[href='#{new_activity_path(initial_oshi_id: record.oshi_id)}']")
    expect(link.text).to eq("この推しの活動を記録")
    get link["href"]
    expect(response).to have_http_status(:ok)
    choices = document.css("input[type='checkbox'][name='activity[oshi_ids][]']")
    expect(choices.map { |choice| choice["value"] }).to contain_exactly(record.oshi_id.to_s, other.oshi_id.to_s)
    expect(choices.select { |choice| choice.key?("checked") }.map { |choice| choice["value"] }).to eq([ record.oshi_id.to_s ])
  end

  it "shows the latest three own activities, including shared-oshi activities, and links to the filtered list" do
    date = Date.new(2026, 10, 1)
    older = activity_for([ record.oshi ], date)
    third = activity_for([ record.oshi ], date + 1)
    second = activity_for([ record.oshi, other.oshi ], date + 2)
    first = activity_for([ record.oshi ], date + 3)
    unrelated = activity_for([ other.oshi ], date + 4)
    foreign_user = create(:user)
    create(:user_oshi, user: foreign_user, oshi: record.oshi)
    foreign = activity_for([ record.oshi ], date + 5, owner: foreign_user)

    get user_oshi_path(record)
    expect(response).to have_http_status(:ok)
    section = document.at_css("section[aria-labelledby='recent-oshi-activities-heading']")
    expect(section.css("li a").map { |link| link["href"] }).to eq([ first, second, third ].map { |activity| activity_path(activity) })
    expect(section.css("time").first["datetime"]).to eq((date + 3).iso8601)
    get section.at_css("a[href='#{activities_path(oshi_id: record.oshi_id)}']")["href"]
    expect(response).to have_http_status(:ok)
    expect(document.at_css("main").text).to include(older.title, second.title)
    expect(document.at_css("main").text).not_to include(unrelated.title, foreign.title)
  end

  it "shows an empty state without removing the quick entry or card link" do
    get user_oshi_path(record)
    expect(response).to have_http_status(:ok)
    expect(document.at_css("section[aria-labelledby='recent-oshi-activities-heading']").text).to include("この推しの活動はまだありません。")
    expect(document.css("main a").map { |a| a["href"] }).to include(
      new_activity_path(initial_oshi_id: record.oshi_id), new_card_path(user_oshi_id: record.id)
    )
  end
end
