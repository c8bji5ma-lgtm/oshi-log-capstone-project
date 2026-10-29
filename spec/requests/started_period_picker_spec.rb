require "rails_helper"

RSpec.describe "Started period picker submission", type: :request do
  let(:user) { create(:user) }
  let(:candidate) { create(:oshi, :approved) }

  before do
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def submit_period(entry, value)
    case entry
    when :new
      post oshis_path, params: { oshi: { name: "選択入力の新規推し", oshi_type: "アイドル" },
        user_oshi: { started_period: value }, continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION }
    when :existing
      post user_oshis_path, params: { oshi_id: candidate.id, user_oshi: { started_period: value },
        continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION }
    when :edit
      @edited = create(:user_oshi, user: user, oshi: candidate, started_period: "2020")
      patch user_oshi_path(@edited), params: { user_oshi: { started_period: value } }
    end
  end

  [ :new, :existing, :edit ].each do |entry|
    [ "1850", "0000/01", "9999/12", "" ].each do |value|
      it "preserves #{value.inspect} through #{entry} without changing its precision" do
        submit_period(entry, value)
        expect(response).to have_http_status(:see_other)
        expected = value.empty? ? nil : value
        expect(user.user_oshis.sole.reload.started_period).to eq(expected)
        if entry != :edit
          expect(response).to redirect_to(new_activity_path(initial_oshi_id: user.user_oshis.sole.oshi_id))
        end
      end
    end

    [ "2020/00", "2020/13", "2020/02/29", "2020\n" ].each do |value|
      it "rejects and redisplays the exact invalid #{value.inspect} through #{entry}" do
        submit_period(entry, value)
        expect(response).to have_http_status(:unprocessable_content)
        source_id = { new: "new_user_oshi_started_period", existing: "existing_user_oshi_started_period", edit: "user_oshi_started_period" }.fetch(entry)
        source = Nokogiri::HTML(response.body).at_css("##{source_id}")
        expect(source["value"]).to eq(value)
        expect(source["aria-invalid"]).to eq("true")
        if entry == :edit
          expect(@edited.reload.started_period).to eq("2020")
        else
          expect(user.user_oshis).to be_empty
        end
      end
    end
  end

  it "keeps unique namespaced ids and the working text fallback before enhancement" do
    get new_oshi_path(q: candidate.name)
    expect(response).to have_http_status(:ok)
    doc = Nokogiri::HTML(response.body)
    ids = doc.css("[id]").map { |node| node["id"] }
    expect(ids.uniq).to eq(ids)
    %w[existing_user_oshi_started_period new_user_oshi_started_period].each do |id|
      source = doc.at_css("##{id}")
      expect(source["name"]).to eq("user_oshi[started_period]")
      expect(source["type"]).to eq("text")
      expect(source.ancestors.any? { |node| node.key?("hidden") }).to be(false)
      picker = source.ancestors.find { |node| node["data-controller"] == "oshi-period" }
      expect(picker.at_css("[data-oshi-period-target='picker']").key?("hidden")).to be(true)
      expect(picker.css("select").all? { |node| node.key?("disabled") && !node.key?("name") }).to be(true)
    end
  end
end
