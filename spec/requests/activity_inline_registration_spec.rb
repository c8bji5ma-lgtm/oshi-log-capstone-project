require "rails_helper"
require_relative "../support/activity_input_context"
require "active_support/testing/time_helpers"

RSpec.describe "Activity input continuity and inline oshi registration", type: :request do
  include ActivityInputContext
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let!(:personal) { create(:user_oshi, user: user, oshi: create(:oshi, :approved)) }
  let!(:candidate) { create(:oshi, :approved) }
  let!(:activity) do
    record = build(:activity, user: user, oshis_count: 0, title: "本人継続の保存済み活動")
    Activities::Save.call(activity: record, oshi_ids: [ personal.oshi_id ])
    record.images.attach(io: File.open(Rails.root.join("spec/fixtures/files/image.png"), "rb"), filename: "saved.png", content_type: "image/png")
    record
  end

  before do
    login(user)
    @token = activity_form_context
  end

  def login(account)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def totals
    [ Activity.count, ActivityOshi.count, Oshi.count, UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
  end

  def headers_for(token, html: false)
    { "ACCEPT" => html ? "text/html" : "application/json", "X-Activity-Panel" => "1", "X-Activity-Context-Token" => token.to_s }
  end

  def perform_operation(operation, token)
    attributes = { occurred_on: "2026-10-01", activity_type: Activity::ACTIVITY_TYPES.first, title: "未保存の活動",
      oshi_ids: [ personal.oshi_id.to_s ], context_token: token,
      images: [ fixture_file_upload(Rails.root.join("spec/fixtures/files/image.png"), "image/png") ] }
    case operation
    when :activity_create
      post activities_path, params: { activity: attributes }
    when :activity_update
      patch activity_path(activity), params: { activity: attributes.merge(lock_version: activity.lock_version.to_s) }
    when :existing
      post user_oshis_path, params: { activity_panel: "1", activity_context_token: token, oshi_id: candidate.id,
        user_oshi: { started_period: "2020/05" } }, headers: headers_for(token)
    when :new
      post oshis_path, params: { activity_panel: "1", activity_context_token: token,
        oshi: { name: "パネルで登録", oshi_type: "アイドル", affiliation: "作品" }, user_oshi: { started_period: "" } },
        headers: headers_for(token)
    when :owned
      get oshis_path, headers: headers_for(token)
    when :panel
      get new_oshi_path, params: { activity_panel: "1" }, headers: headers_for(token, html: true)
    when :suggestions
      get new_oshi_path, params: { activity_panel: "1", q: candidate.name, suggest: "1" }, headers: headers_for(token, html: true)
    end
  end

  operations = [ :activity_create, :activity_update, :existing, :new, :owned, :panel, :suggestions ]
  operations.each do |operation|
    it "allows the original authenticated actor for #{operation}" do
      perform_operation(operation, @token)
      expect(response).to have_http_status([ :activity_create, :activity_update ].include?(operation) ? :see_other : ([ :owned, :panel, :suggestions ].include?(operation) ? :ok : :created))
      expect(response.headers["Cache-Control"]).to include("no-store") unless [ :activity_create, :activity_update ].include?(operation)
      if operation == :panel
        page = Nokogiri::HTML(response.body)
        expect(page.css("form").size).to eq(3)
        expect(page.css("form form")).to be_empty
        expect(page.css("input[type='file']")).to be_empty
        expect(page.text).to include("新しい推しは承認待ち")
      elsif operation == :suggestions
        page = Nokogiri::HTML(response.body)
        expect(page.at_css("#oshi-search-results")["data-oshi-search-mode"]).to eq("suggestions")
        expect(page.css("input[name='oshi_id']").map { |input| input["value"] }).to eq([ candidate.id.to_s ])
        expect(page.css("form,script,input[name='activity_context_token'],input[name='authenticity_token']")).to be_empty
        expect(response.body).not_to include(@token)
      elsif operation == :new
        created = user.user_oshis.find_by!(oshi: Oshi.find(JSON.parse(response.body).dig("oshi", "id")))
        expect(created.oshi).to be_pending
        expect(created.started_period).to be_nil
      elsif operation == :owned
        ids = JSON.parse(response.body).fetch("oshis").map { |item| item.dig("oshi", "id") }
        expect(ids).to contain_exactly(personal.oshi_id)
      end
    end

    [ :missing, :tampered, :wrong_purpose, :expired ].each do |invalid|
      it "rejects #{invalid} context for #{operation} without changing data or saved images" do
        token = case invalid
        when :missing then nil
        when :tampered then (@token.start_with?("a") ? "b" : "a") + @token[1..]
        when :wrong_purpose
          payload = Rails.application.message_verifier("activity_input").verified(@token, purpose: "activity_input")
          Rails.application.message_verifier("activity_input").generate(payload, purpose: "different", expires_in: 2.hours)
        else @token
        end
        before = totals
        saved = activity.images.blobs.ids
        if invalid == :expired
          travel 2.hours + 1.second do
            perform_operation(operation, token)
          end
        else
          perform_operation(operation, token)
        end
        expect(response).to have_http_status(:conflict)
        expect(totals).to eq(before)
        expect(activity.reload).to have_attributes(title: "本人継続の保存済み活動")
        expect(activity.images.blobs.ids).to eq(saved)
        expect(response.body).not_to include('name="activity[context_token]"')
      end
    end

    it "rejects the old actor's #{operation} after switching to another account" do
      delete destroy_user_session_path
      login(other)
      before = totals
      perform_operation(operation, @token)
      expect(response).to have_http_status(operation == :activity_update ? :not_found : :conflict)
      expect(totals).to eq(before)
      expect(activity.reload.title).to eq("本人継続の保存済み活動")
    end

    it "rejects #{operation} after logout" do
      delete destroy_user_session_path
      before = totals
      perform_operation(operation, @token)
      expect([ 302, 303, 401 ]).to include(response.status)
      expect(totals).to eq(before)
    end
  end

  it "invalidates the old context after the same account signs in again and accepts a fresh form" do
    delete destroy_user_session_path
    login(user)
    before = totals
    perform_operation(:activity_create, @token)
    expect(response).to have_http_status(:conflict)
    expect(totals).to eq(before)
    perform_operation(:activity_create, activity_form_context)
    expect(response).to have_http_status(:see_other)
  end

  it "keeps duplicate personal registration periods unchanged" do
    personal.update!(started_period: "2018", ended_period: "2020")
    before = totals
    post user_oshis_path, params: { activity_panel: "1", activity_context_token: @token, oshi_id: personal.oshi_id,
      user_oshi: { started_period: "2024" } }, headers: headers_for(@token)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["result"]).to eq("already_registered")
    expect(totals).to eq(before)
    expect(personal.reload).to have_attributes(started_period: "2018", ended_period: "2020")
  end

  it "preserves pending and ownership restrictions for new registration and candidate addition" do
    post oshis_path, params: { activity_panel: "1", activity_context_token: @token,
      oshi: { name: "本人だけの申請", oshi_type: "声優", status: "approved", created_by_user_id: other.id },
      user_oshi: { user_id: other.id } }, headers: headers_for(@token)
    expect(response).to have_http_status(:created)
    created = Oshi.find(JSON.parse(response.body).dig("oshi", "id"))
    expect(created).to have_attributes(status: "pending", created_by_user_id: user.id)
    hidden = create(:oshi, :pending, created_by_user: other)
    before = totals
    post user_oshis_path, params: { activity_panel: "1", activity_context_token: @token, oshi_id: hidden.id }, headers: headers_for(@token)
    expect(response).to have_http_status(:not_found)
    expect(totals).to eq(before)
  end

  it "rolls back both new records for an invalid period and rejects panel photo uploads" do
    before = totals
    post oshis_path, params: { activity_panel: "1", activity_context_token: @token,
      oshi: { name: "期間エラー", oshi_type: "アイドル" }, user_oshi: { started_period: "2020/13" } }, headers: headers_for(@token)
    expect(response).to have_http_status(:unprocessable_content)
    expect(totals).to eq(before)
    post oshis_path, params: { activity_panel: "1", activity_context_token: @token,
      oshi: { name: "写真なしのパネル", oshi_type: "アイドル" },
      user_oshi: { library_images: [ fixture_file_upload("image.png", "image/png") ] } }, headers: headers_for(@token)
    expect(response).to have_http_status(:unprocessable_content)
    expect(totals).to eq(before)
  end


  [ :owned, :panel, :existing, :new, :suggestions ].each do |operation|
    it "identifies anonymous panel #{operation} while preserving ordinary HTML login redirect", :h04_auth_boundary do
      delete destroy_user_session_path
      before = totals
      perform_operation(operation, @token)
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Location"]).to be_nil
      expect(JSON.parse(response.body)).to eq({ "error" => "context", "message" => I18n.t("ui.activity_panel.context_error") })
      expect(response.body).not_to include(@token)
      case operation
      when :owned then get oshis_path
      when :panel then get new_oshi_path
      when :suggestions then get new_oshi_path, params: { q: candidate.name, suggest: "1" }
      when :existing then post user_oshis_path, params: { oshi_id: candidate.id }
      when :new then post oshis_path, params: { oshi: { name: "未認証では保存しない", oshi_type: "アイドル" } }
      end
      expect(response).to redirect_to(new_user_session_path)
      expect(totals).to eq(before)
    end
  end

  it "filters context tokens using the existing parameter filter" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      { "activity" => { "context_token" => "example" }, "activity_context_token" => "example", "HTTP_X_ACTIVITY_CONTEXT_TOKEN" => "example" })
    expect(filtered).to eq({ "activity" => { "context_token" => "[FILTERED]" }, "activity_context_token" => "[FILTERED]", "HTTP_X_ACTIVITY_CONTEXT_TOKEN" => "[FILTERED]" })
  end
end

RSpec.describe "Read-only guest inline activity registration", type: :request do
  include ActivityInputContext

  around do |example|
    previous = ENV["OSHI_GUEST_SANDBOX"]
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    example.run
  ensure
    previous.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous
  end

  it "rejects panel reads and writes even with a valid guest activity context" do
    create(:user, email: "demo@example.com")
    create(:user, :admin, email: "admin@example.com")
    %w[multi light empty].each { |name| create(:user, email: "#{name}@example.com") }
    post guest_session_path(role: "admin")
    token = activity_form_context
    headers = { "ACCEPT" => "application/json", "X-Activity-Panel" => "1", "X-Activity-Context-Token" => token }
    before = [ Oshi.count, UserOshi.count, Activity.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    get oshis_path, headers: headers
    expect(response).to have_http_status(:forbidden)
    get new_oshi_path, params: { activity_panel: "1" }, headers: headers
    expect(response).to have_http_status(:forbidden)
    post oshis_path, params: { activity_panel: "1", activity_context_token: token, oshi: { name: "保存しない", oshi_type: "アイドル" } }, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect([ Oshi.count, UserOshi.count, Activity.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(before)
  end
end
