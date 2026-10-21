require "rails_helper"

RSpec.describe "Activity emotion tags", type: :request do
  include_context "emotion master data"

  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved) }
  let(:happy) { Emotion.find_by!(name: "嬉しい") }
  let(:moved) { Emotion.find_by!(name: "感動") }
  let(:lonely) { Emotion.find_by!(name: "寂しい") }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def input(**changes)
    { occurred_on: "2026-10-01", title: "感情を記録", activity_type: "ライブ・イベント", oshi_ids: [ oshi.id.to_s ] }.merge(changes)
  end

  def activity_for(owner = user, emotions: [])
    record = build(:activity, :without_oshis, user: owner)
    UserOshi.find_or_create_by!(user: owner, oshi: oshi)
    Activities::Save.call(activity: record, oshi_ids: [ oshi.id ], emotion_ids: emotions.map(&:id))
  end

  def versioned(record, values)
    values.merge(lock_version: record.lock_version.to_s)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def selected_ids
    document.css("select[name='activity[emotion_ids][]'] option[selected]").map { |option| option["value"] }
  end

  it "offers the ordered optional multiple selection in new and edit, including an empty hidden value" do
    record = activity_for(emotions: [ moved, happy ])
    [ new_activity_path, edit_activity_path(record) ].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      select = document.at_css("select[name='activity[emotion_ids][]']")
      expect(select["multiple"]).to be_present
      expect(select["required"]).to be_nil
      expect(select.css("option").map(&:text)).to eq(%w[嬉しい 興奮 驚き 感動 幸せ 悔しい 寂しい])
      expect(document.at_css("input[type='hidden'][name='activity[emotion_ids][]']")["value"]).to eq("")
      expect(selected_ids).to eq(path == new_activity_path ? [] : [ happy.id.to_s, moved.id.to_s ])
    end
  end

  it "creates multiple tags once even when duplicate IDs are submitted" do
    expect do
      post activities_path, params: { activity: input(emotion_ids: [ "", moved.id.to_s, happy.id.to_s, happy.id.to_s ]) }
    end.to change(Activity, :count).by(1).and change(ActivityEmotion, :count).by(2)
    expect(response).to redirect_to(activities_path)
    expect(user.activities.last.emotions).to eq([ happy, moved ])
  end

  [ :omitted, [], [ "" ] ].each do |selection|
    it "registers without tags for #{selection.inspect}" do
      values = selection == :omitted ? input : input(emotion_ids: selection)
      post activities_path, params: { activity: values }
      expect(response).to redirect_to(activities_path)
      expect(user.activities.last.emotions).to be_empty
    end
  end

  it "replaces and clears tags, and preserves them when the parameter is omitted" do
    record = activity_for(emotions: [ happy, moved ])
    patch activity_path(record), params: { activity: versioned(record, input(title: "本文だけ更新")) }
    expect(response).to redirect_to(activity_path(record))
    expect(record.reload.emotions).to eq([ happy, moved ])
    patch activity_path(record), params: { activity: versioned(record, input(emotion_ids: [ moved.id.to_s, lonely.id.to_s ])) }
    expect(response).to redirect_to(activity_path(record))
    expect(record.reload.emotions).to eq([ moved, lonely ])
    [ [], [ "" ] ].each do |ids|
      record.emotions = [ happy ]
      patch activity_path(record), params: { activity: versioned(record, input(emotion_ids: ids)) }
      expect(response).to redirect_to(activity_path(record))
      expect(record.reload.emotions).to be_empty
    end
  end

  [ nil, "1", { id: "1" }, [ "bad" ], [ "0" ], [ "-1" ], [ "1foo" ], [ "1.0" ], [ " 1" ], [ [ "1" ] ], [ { id: "1" } ], [ 1 ] ].each do |ids|
    it "rejects malformed selection #{ids.inspect} without writing records or links" do
      record = activity_for(emotions: [ happy ])
      original = record.attributes
      counts = [ Activity.count, ActivityOshi.count, ActivityEmotion.count ]
      post activities_path, params: { activity: input(emotion_ids: ids) }, as: :json, headers: { "ACCEPT" => "text/html" }
      expect(response).to have_http_status(:unprocessable_content)
      patch activity_path(record), params: { activity: versioned(record, input(emotion_ids: ids)) }, as: :json, headers: { "ACCEPT" => "text/html" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("select[name='activity[emotion_ids][]']")["aria-invalid"]).to eq("true")
      expect(record.reload.attributes).to eq(original)
      expect(record.emotions).to eq([ happy ])
      expect([ Activity.count, ActivityOshi.count, ActivityEmotion.count ]).to eq(counts)
    end
  end

  it "rejects nonexistent IDs together with valid IDs rather than silently dropping them" do
    missing = (Emotion.maximum(:id) + 1).to_s
    record = activity_for(emotions: [ happy ])
    post activities_path, params: { activity: input(emotion_ids: [ moved.id.to_s, missing ]) }
    expect(response).to have_http_status(:unprocessable_content)
    expect(user.activities.count).to eq(1)
    patch activity_path(record), params: { activity: versioned(record, input(emotion_ids: [ moved.id.to_s, missing ])) }
    expect(response).to have_http_status(:unprocessable_content)
    expect(record.reload.emotions).to eq([ happy ])
  end

  [ { title: "" }, { oshi_ids: [] }, { images: [ "untrusted-signed-id" ] } ].each do |invalid|
    it "retains submitted tags in an invalid form and leaves stored values unchanged for #{invalid.inspect}" do
      record = activity_for(emotions: [ happy ])
      patch activity_path(record), params: { activity: versioned(record, input(emotion_ids: [ moved.id.to_s ], **invalid)) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(selected_ids).to eq([ moved.id.to_s ])
      expect(record.reload.emotions).to eq([ happy ])
      expect(record.oshi_ids).to eq([ oshi.id ])
    end
  end

  it "shows tags per activity in display order without duplicating filtered rows or exposing other users' tags" do
    tagged = activity_for(emotions: [ moved, happy ])
    untagged = activity_for
    activity_for(create(:user), emotions: [ lonely ])
    get activities_path, params: { oshi_id: oshi.id.to_s }
    expect(response).to have_http_status(:ok)
    rows = document.css(".activity-list li")
    expect(rows.size).to eq(2)
    row = rows.find { |item| item.at_css("a")["href"] == activity_path(tagged) }
    expect(row.at_css(".activity-emotions").text).to eq("嬉しい、感動")
    expect(response.body).not_to include("寂しい")
    get activity_path(tagged)
    expect(document.at_css(".activity-emotions").text).to eq("嬉しい、感動")
    get activity_path(untagged)
    expect(document.at_css(".activity-emotions").text).to eq("—")
    patch activity_path(untagged), params: { activity: versioned(untagged, input) }
    expect(response).to redirect_to(activity_path(untagged))
  end

  it "rejects reading, editing, updating and deleting another user's tagged activity" do
    record = activity_for(create(:user), emotions: [ happy ])
    original = record.attributes
    [ activity_path(record), edit_activity_path(record) ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
    patch activity_path(record), params: { activity: input(emotion_ids: [ moved.id.to_s ]) }
    expect(response).to have_http_status(:not_found)
    delete activity_path(record)
    expect(response).to have_http_status(:not_found)
    expect(record.reload.attributes).to eq(original)
    expect(record.emotions).to eq([ happy ])
  end

  it "ignores injected association ownership parameters when updating owned tags" do
    other = activity_for(create(:user), emotions: [ happy ])
    owned = activity_for
    link = other.activity_emotions.first
    patch activity_path(owned), params: { activity: versioned(owned, input(emotion_ids: [ moved.id.to_s ], user_id: other.user_id,
      activity_emotions_attributes: [ { id: link.id, activity_id: owned.id, emotion_id: lonely.id, _destroy: true } ])) }
    expect(response).to redirect_to(activity_path(owned))
    expect(owned.reload.user_id).to eq(user.id)
    expect(owned.emotions).to eq([ moved ])
    expect(other.reload.emotions).to eq([ happy ])
    expect(link.reload.activity_id).to eq(other.id)
  end

  it "deletes owned links while retaining master tags and other users' links" do
    owned = activity_for(emotions: [ happy, moved ])
    other = activity_for(create(:user), emotions: [ happy ])
    expect { delete activity_path(owned) }.to change(ActivityEmotion, :count).by(-2)
    expect(response).to redirect_to(activities_path)
    expect(Activity.exists?(owned.id)).to be(false)
    expect(other.reload.emotions).to eq([ happy ])
    expect(Emotion.where(id: [ happy.id, moved.id ]).count).to eq(2)
  end
end
