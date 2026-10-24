require "rails_helper"

RSpec.describe "Oshi search and registration", type: :request do
  let(:user) { create(:user) }

  def document
    Nokogiri::HTML(response.body)
  end

  def register(attributes = {}, periods = nil, continuation: nil, extra: {}, **period_keywords)
    periods = (periods || {}).merge(period_keywords)
    post oshis_path, params: {
      oshi: { name: "新しい推し", oshi_type: "アイドル", affiliation: "所属" }.merge(attributes),
      user_oshi: { started_period: "2023/05" }.merge(periods),
      continue: continuation
    }.merge(extra)
  end

  context "when signed out" do
    it "requires login for search and registration" do
      get new_oshi_path
      expect(response).to redirect_to(new_user_session_path)
      expect { register }.not_to change(Oshi, :count)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context "when signed in" do
    before { post user_session_path, params: { user: { email: user.email, password: "password123" } } }

    it "searches approved and own pending while hiding unavailable statuses" do
      approved = create(:oshi, :approved, name: "承認済み", affiliation: "検索対象作品")
      own = create(:oshi, :pending, name: "本人申請", affiliation: "検索対象作品", created_by_user: user)
      create(:oshi, :pending, name: "他人申請", affiliation: "検索対象作品", created_by_user: create(:user))
      create(:oshi, :pending, name: "登録者なし", affiliation: "検索対象作品")
      create(:oshi, :rejected, name: "却下済み", affiliation: "検索対象作品", created_by_user: user)
      get new_oshi_path, params: { q: "検索対象作品" }
      expect(response).to have_http_status(:ok)
      expect(document.css("input[type='radio'][name='oshi_id']").map { |input| input["value"] })
        .to contain_exactly(approved.id.to_s, own.id.to_s)
      expect(document.at_css("main").text).not_to include("他人申請", "登録者なし", "却下済み")
    end

    it "matches names, aliases and affiliations case-insensitively without duplicates" do
      oshi = create(:oshi, :approved, name: "対象")
      create(:oshi_alias, oshi: oshi, alias_name: "CANDY first")
      create(:oshi_alias, oshi: oshi, alias_name: "candy second")
      affiliated = create(:oshi, :approved, name: "所属だけ", affiliation: "Candy作品")
      hidden = create(:oshi, :pending, name: "他人", created_by_user: create(:user))
      hidden.update!(affiliation: "candy")
      get new_oshi_path, params: { q: "cAnDy" }
      expect(document.css("input[type='radio'][name='oshi_id']").map { |input| input["value"] })
        .to contain_exactly(oshi.id.to_s, affiliated.id.to_s)
      expect(document.css("input[type='radio'][name='oshi_id'][value='#{oshi.id}']").size).to eq(1)
      expect(document.at_css("main").text).not_to include("他人")
    end

    it "limits broad search results, keeps stable ordering and identifies same-name candidates" do
      matching = create_list(:oshi, 52, :approved, name: "同名候補").sort_by(&:id)
      get new_oshi_path, params: { q: "同名候補" }

      options = document.css("input[type='radio'][name='oshi_id']")
      expect(options.map { |input| input["value"] }).to eq(matching.first(50).map { |oshi| oshi.id.to_s })
      expect(document.at_css("label[for='oshi_id_#{matching.first.id}']").text).to include("同名候補", "承認済み")
      expect(document.css("[role='status']").map(&:text).join)
        .to include("最大50件", "名前・別名・所属・作品を入力して絞り込んでください")
      expect(document.at_css("input[name='q']")["placeholder"]).to include("所属・作品")
    end

    [ "%", "_", "\\" ].each do |query|
      it "escapes #{query.inspect} in the search request" do
        match = create(:oshi, :approved, name: "literal#{query}target")
        create(:oshi, :approved, name: "literalXtarget")
        get new_oshi_path, params: { q: query }
        expect(document.css("input[type='radio'][name='oshi_id']").map { |input| input["value"] })
          .to eq([ match.id.to_s ])
      end
    end
    it "shows one active common image with matching attribution and ignores inactive images" do
      oshi = create(:oshi, :approved, name: "画像候補")
      active = create(:oshi_common_image, oshi: oshi, attribution_text: "表示する帰属")
      create(:oshi_common_image, oshi: oshi, active: false, attribution_text: "表示しない帰属")

      get new_oshi_path, params: { q: oshi.name }

      image = document.at_css("label[for='oshi_id_#{oshi.id}'] img")
      expect(image["src"]).to eq(common_oshi_image_path(active.image.attachment))
      expect(document.at_css("main").text).to include("表示する帰属", active.license_name)
      expect(document.at_css("main").text).not_to include("表示しない帰属")
    end

    it "preloads bounded metadata for fifty candidates with ten records each" do
      oshis = create_list(:oshi, 50, :approved, name: "大量共通画像候補")
      now = Time.current
      rows = oshis.flat_map do |oshi|
        10.times.map do |index|
          { oshi_id: oshi.id, source_url: "https://example.test/#{oshi.id}/#{index}",
            creator_name: "作者", license_name: "許諾", attribution_text: "帰属",
            rights_confirmed_at: now, active: true, lock_version: 0,
            created_at: now, updated_at: now }
        end
      end
      OshiCommonImage.insert_all!(rows)
      queries = []
      subscriber = lambda do |*, payload|
        sql = payload[:sql]
        queries << sql if sql.include?("oshi_common_images") || sql.include?("active_storage_attachments") ||
          sql.include?("active_storage_blobs")
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get new_oshi_path, params: { q: "大量共通画像候補" }
      end

      expect(response).to have_http_status(:ok)
      expect(document.css("input[name='oshi_id']").size).to eq(50)
      expect(queries.grep(/SELECT/).size).to be <= 3
    end


    it "shows no candidates before a search or for whitespace" do
      create(:oshi, :approved, name: "大量表示しない推し")
      [ nil, " " ].each do |query|
        get new_oshi_path, params: { q: query }
        expect(document.css("input[name='oshi_id']")).to be_empty
        expect(document.at_css("main").text).not_to include("大量表示しない推し")
      end
    end

    it "safely returns no candidates for a long unmatched query" do
      create(:oshi, :approved, affiliation: "短い所属")
      get new_oshi_path, params: { q: "該当しない検索語" * 100 }

      expect(response).to have_http_status(:ok)
      expect(document.css("input[name='oshi_id']")).to be_empty
      expect(document.at_css("main").text).to include("該当する推しが見つかりませんでした。")
    end

    it "creates both records with server-controlled ownership and pending status" do
      other = create(:user)
      expect do
        register({ status: "approved", created_by_user_id: other.id }, { user_id: other.id, ended_period: "2025" })
      end.to change(Oshi, :count).by(1).and change(UserOshi, :count).by(1)
      oshi = Oshi.order(:id).last
      link = UserOshi.order(:id).last
      expect(oshi).to have_attributes(status: "pending", created_by_user_id: user.id, affiliation: "所属")
      expect(link).to have_attributes(user_id: user.id, oshi_id: oshi.id, started_period: "2023/05", ended_period: nil)
      expect(response).to redirect_to(oshis_path)
      follow_redirect!
      expect(document.at_css("[role='status']").text).to include("推しを登録しました")
      expect(document.at_css("main").text).to include("新しい推し", "2023/05")
    end

    it "preserves the allowlisted first-activity context through search and validation errors" do
      get new_oshi_path, params: { q: "候補", continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION }
      expect(document.css("input[name='continue']").map { |input| input["value"] }.uniq)
        .to eq([ ApplicationController::FIRST_ACTIVITY_CONTINUATION ])

      register({ name: "" }, { started_period: "2023/13" },
        continuation: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("input#new_continue")["value"]).to eq(ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(document.at_css("input[name='user_oshi[started_period]']")["value"]).to eq("2023/13")
    end

    it "continues a newly registered pending oshi to a preselected first activity" do
      register({}, {}, continuation: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      created = user.user_oshis.last!
      expect(created.oshi).to be_pending
      expect(response).to redirect_to(new_activity_path(initial_oshi_id: created.oshi_id))
      follow_redirect!
      expect(document.at_css("input[type='checkbox'][name='activity[oshi_ids][]'][checked]")["value"]).to eq(created.oshi_id.to_s)
      expect(document.at_css("input[name='activity[occurred_on]']")["value"]).to eq(Date.current.iso8601)
    end

    it "ignores arbitrary continuation and redirect parameters" do
      register({}, {}, continuation: "https://example.test/steal", extra: { return_to: "https://example.test/steal" })
      expect(response).to redirect_to(oshis_path)
    end

    it "allows an unspecified starting period" do
      register({}, started_period: "")
      expect(response).to redirect_to(oshis_path)
      expect(user.user_oshis.last.started_period).to be_nil
    end

    it "persists neither record and shows both model errors for invalid input" do
      expect { register({ name: "" }, { started_period: "2023/13" }) }
        .to change(Oshi, :count).by(0).and change(UserOshi, :count).by(0)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css(".validation-errors[role='alert']").size).to eq(2)
      expect(document.at_css("input[name='user_oshi[started_period]']")["value"]).to eq("2023/13")
    end

    it "rolls back the saved oshi when the user period is invalid" do
      expect { register({}, started_period: "2023-05") }
        .to change(Oshi, :count).by(0).and change(UserOshi, :count).by(0)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("input[name='oshi[name]']")["value"]).to eq("新しい推し")
      expect(document.at_css("input[name='user_oshi[started_period]']")["aria-invalid"]).to eq("true")
      expect(document.css(".validation-errors")).not_to be_empty
    end

    it "keeps registration fields limited to the existing schema" do
      get new_oshi_path
      expect(document.css("textarea")).to be_empty
      expect(document.css("input[name*='status'], input[name*='created_by_user'], input[name*='user_id']")).to be_empty
    end
  end
end
