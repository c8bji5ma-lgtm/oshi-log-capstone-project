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


    it "shows at most twelve stable catalog choices before search and for whitespace without registering" do
      visible = 14.times.map { |index| create(:oshi, :approved, name: format("候補%02d", index)) }
      own_pending = create(:oshi, :pending, name: "候補00本人", created_by_user: user)
      foreign = create(:oshi, :pending, name: "他人の非公開候補", created_by_user: create(:user))
      rejected = create(:oshi, :rejected, name: "本人でも却下済み", created_by_user: user)
      added = create(:user_oshi, user: user, oshi: visible.first)
      expected = (visible + [ own_pending ]).sort_by { |record| [ record.name, record.id ] }.first(12)
      counts = [ Oshi.count, UserOshi.count ]

      [ nil, "", " ", "　" ].each do |query|
        get new_oshi_path, params: { q: query }
        result = document.at_css("#oshi-search-results")
        expect(result["data-oshi-search-state"]).to eq("initial")
        expect(result["data-oshi-search-count"]).to eq("12")
        expect(result.css("input[name='oshi_id']").map { |input| input["value"] }).to eq(expected.map { |record| record.id.to_s })
        expect(result.css("input[checked]")).to be_empty
        expect(result.at_css("[data-catalog-oshi-id='#{added.oshi_id}']").text).to include("追加済み")
        expect(result.at_css("[data-catalog-oshi-id='#{visible[1].id}']").text).to include("未追加")
        expect(result.text).to include("最大12件", "横にスクロール", "上の検索", "選ぶだけでは追加されません")
        expect(result.text).not_to include(foreign.name, rejected.name, I18n.t("ui.oshi.no_results"))
        expect(document.at_css("#oshi_name")["value"]).to be_blank
        expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      end
    end

    it "identifies a successful empty search without creating a record or pre-filling the server form" do
      query = "未登録の推し<&>"
      expect {
        get new_oshi_path, params: { q: query, continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION }
      }.not_to change(Oshi, :count)
      expect(response).to have_http_status(:ok)
      result = document.at_css("#oshi-search-results")
      expect(result["data-oshi-search-query"]).to eq(query)
      expect(result["data-oshi-search-state"]).to eq("empty")
      expect(result["data-oshi-search-count"]).to eq("0")
      expect(document.at_css("#oshi_name")["value"]).to be_blank
      expect(document.at_css("#new_continue")["value"]).to eq(ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(document.at_css("#existing_query")["value"]).to eq(query)
    end

    it "distinguishes unsubmitted and whitespace searches from successful matching results" do
      [ nil, "", "  ", "　" ].each do |query|
        get new_oshi_path, params: { q: query }
        expect(document.at_css("#oshi-search-results")["data-oshi-search-state"]).to eq("initial")
      end
      candidate = create(:oshi, :approved, name: "検索が成功した候補")
      get new_oshi_path, params: { q: candidate.name }
      result = document.at_css("#oshi-search-results")
      expect(result["data-oshi-search-state"]).to eq("results")
      expect(result["data-oshi-search-count"]).to eq("1")
      expect(result.at_css("input[name='oshi_id']")["value"]).to eq(candidate.id.to_s)
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
      expect(document.at_css("#new_user_oshi_started_period")["value"]).to eq("2023/13")
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
      expect(document.at_css("#new_user_oshi_started_period")["value"]).to eq("2023/13")
    end

    it "rolls back the saved oshi when the user period is invalid" do
      expect { register({}, started_period: "2023-05") }
        .to change(Oshi, :count).by(0).and change(UserOshi, :count).by(0)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("input[name='oshi[name]']")["value"]).to eq("新しい推し")
      expect(document.at_css("#new_user_oshi_started_period")["aria-invalid"]).to eq("true")
      expect(document.css(".validation-errors")).not_to be_empty
    end

    it "keeps registration fields limited to the existing schema" do
      get new_oshi_path
      expect(document.css("textarea")).to be_empty
      expect(document.css("input[name*='status'], input[name*='created_by_user'], input[name*='user_id']")).to be_empty
    end

    it "renders only safe active common images or placeholders in both live and cached catalog cards" do
      with_image = create(:oshi, :approved, name: "画像あり")
      without_image = create(:oshi, :approved, name: "画像なし")
      active = create(:oshi_common_image, oshi: with_image, attribution_text: "安全な共通画像の帰属")
      inactive = create(:oshi_common_image, oshi: without_image, active: false, attribution_text: "無効画像の帰属")
      private_oshi = create(:oshi, :pending, name: "非公開共通画像候補", created_by_user: create(:user))
      hidden = create(:oshi_common_image, oshi: private_oshi)
      foreign_registration = create(:user_oshi, oshi: with_image)
      foreign_registration.representative_image.attach(io: File.open(Rails.root.join("spec/fixtures/files/image.png")), filename: "private.png", content_type: "image/png")

      get new_oshi_path
      result = document.at_css("#oshi-search-results")
      image = result.at_css("label[for='oshi_id_#{with_image.id}'] img")
      expect(image["src"]).to eq(common_oshi_image_path(active.image.attachment))
      expect(result.at_css("label[for='oshi_id_#{without_image.id}'] img")["src"]).to include("image_placeholder")
      expect(result.text).to include(active.attribution_text, active.license_name)
      expect(response.body).not_to include(inactive.attribution_text, hidden.attribution_text, private_oshi.name,
        common_oshi_image_path(inactive.image.attachment), common_oshi_image_path(hidden.image.attachment),
        protected_image_path(foreign_registration.representative_image.attachment))
      snapshot = Nokogiri::HTML(JSON.parse(document.at_css("[data-oshi-registration-target='catalogSnapshot']").text))
      expect(snapshot.css("input[name='oshi_id']").map { |input| input["value"] }).to match_array([ with_image.id.to_s, without_image.id.to_s ])
      expect(snapshot.css("form, input[type='hidden'], input[checked]")).to be_empty
      expect(snapshot.css("[data-oshi-registration-context-token-value], [name='activity_context_token']")).to be_empty
    end

    it "escapes catalog labels and the JSON snapshot without creating executable markup" do
      dangerous = create(:oshi, :approved, name: "</script><script data-catalog-injection>危険な名前</script>")
      get new_oshi_path
      expect(document.css("script[data-catalog-injection]")).to be_empty
      expect(document.at_css("label[for='oshi_id_#{dangerous.id}'] strong").text).to eq(dangerous.name)
      snapshot = Nokogiri::HTML(JSON.parse(document.at_css("[data-oshi-registration-target='catalogSnapshot']").text))
      expect(snapshot.css("script")).to be_empty
      expect(snapshot.at_css("label strong").text).to eq(dangerous.name)
    end

    it "preloads common image metadata in three selects for the bounded initial catalog" do
      14.times { |index| create(:oshi, :approved, name: format("初期候補%02d", index)) }
      queries = []
      subscriber = lambda do |*, payload|
        sql = payload[:sql]
        queries << sql if sql.include?("oshi_common_images") || sql.include?("active_storage_attachments") || sql.include?("active_storage_blobs")
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get new_oshi_path }
      expect(document.css("#oshi-search-results input[name='oshi_id']").size).to eq(12)
      expect(queries.grep(/SELECT/).size).to be <= 3
    end

    it "keeps an empty catalog distinct from an explicit zero-result search" do
      create(:oshi, :pending, created_by_user: create(:user))
      get new_oshi_path
      result = document.at_css("#oshi-search-results")
      expect(result["data-oshi-search-state"]).to eq("initial")
      expect(result["data-oshi-search-count"]).to eq("0")
      expect(result.text).to include(I18n.t("ui.oshi.catalog.empty"))
      expect(result.text).not_to include(I18n.t("ui.oshi.no_results"))
      expect(document.at_css("#oshi_name")["value"]).to be_blank
      get new_oshi_path, params: { q: "まだない推し" }
      expect(document.at_css("#oshi-search-results")["data-oshi-search-state"]).to eq("empty")
      expect(document.at_css("#oshi-search-results").text).to include(I18n.t("ui.oshi.no_results"))
    end

    it "returns at most eight ordered input suggestions with personal added state and no registration or form tokens" do
      candidates = 10.times.map { |index| create(:oshi, :approved, name: format("入力候補%02d", index)) }
      own = create(:oshi, :pending, name: "入力候補00本人", created_by_user: user)
      foreign = create(:oshi, :pending, name: "入力候補の非公開", created_by_user: create(:user))
      rejected = create(:oshi, :rejected, name: "入力候補の却下", created_by_user: user)
      create(:user_oshi, user: user, oshi: candidates.first)
      expected = (candidates + [ own ]).sort_by { |record| [ record.name, record.id ] }.first(8)
      counts = [ Oshi.count, UserOshi.count ]
      get new_oshi_path, params: { q: "入力候補", suggest: "1" }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("private", "no-store")
      result = document.at_css("#oshi-search-results")
      expect(result["data-oshi-search-mode"]).to eq("suggestions")
      expect(result["data-oshi-search-state"]).to eq("results")
      expect(result["data-oshi-search-count"]).to eq("8")
      expect(result.css("input[name='oshi_id']").map { |input| input["value"] }).to eq(expected.map { |record| record.id.to_s })
      expect(result.css("[role='option']").map { |option| option["data-oshi-id"] }).to eq(expected.map { |record| record.id.to_s })
      expect(result.css("input[checked]")).to be_empty
      expect(result.css("input[name='oshi_id']")).to all(satisfy { |input| input["type"] == "radio" && !input["hidden"].nil? })
      expect(result.at_css("[data-oshi-id='#{candidates.first.id}']").text).to include("追加済み")
      expect(result.at_css("[data-oshi-id='#{own.id}']").text).to include("未追加", "承認待ち")
      expect(response.body).not_to include(foreign.name, rejected.name, "activity_context_token", "authenticity_token")
      expect(document.css("form,script,[data-controller]")).to be_empty
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
    end

    it "uses names, aliases and affiliations for input suggestions without duplicate IDs" do
      named = create(:oshi, :approved, name: "Candy本人")
      aliased = create(:oshi, :approved, name: "別名の候補")
      create(:oshi_alias, oshi: aliased, alias_name: "CANDY first")
      create(:oshi_alias, oshi: aliased, alias_name: "candy second")
      affiliated = create(:oshi, :approved, affiliation: "Candy作品")
      get new_oshi_path, params: { q: "cAnDy", suggest: "1" }
      expect(document.css("input[name='oshi_id']").map { |input| input["value"] }).to contain_exactly(named.id.to_s, aliased.id.to_s, affiliated.id.to_s)
    end

    [ "%", "_", "\\" ].each do |query|
      it "escapes #{query.inspect} in input suggestions" do
        matching = create(:oshi, :approved, name: "候補#{query}だけ")
        create(:oshi, :approved, name: "候補Xだけ")
        get new_oshi_path, params: { q: query, suggest: "1" }
        expect(document.css("input[name='oshi_id']").map { |input| input["value"] }).to eq([ matching.id.to_s ])
      end
    end

    it "keeps blank input initial and a successful unmatched input empty without copying a registration name" do
      create(:oshi, :approved, name: "既存のカード候補")
      [ "", " ", "　" ].each do |query|
        get new_oshi_path, params: { q: query, suggest: "1" }
        expect(document.at_css("#oshi-search-results")["data-oshi-search-state"]).to eq("initial")
        expect(document.css("input[name='oshi_id']")).to be_empty
      end
      get new_oshi_path, params: { q: "未登録の入力候補", suggest: "1" }
      expect(document.at_css("#oshi-search-results")["data-oshi-search-state"]).to eq("empty")
      expect(document.at_css("#oshi-search-results")["data-oshi-search-count"]).to eq("0")
      expect(document.css("input[name='oshi[name]'],form")).to be_empty
    end

    it "escapes suggestion names and serves only safe active common images with attribution" do
      named = create(:oshi, :approved, name: "<script data-suggestion-injection>候補</script>")
      plain = create(:oshi, :approved, name: "候補のplaceholder")
      active = create(:oshi_common_image, oshi: named, attribution_text: "安全な候補画像")
      inactive = create(:oshi_common_image, oshi: plain, active: false, attribution_text: "表示しない無効候補画像")
      hidden_oshi = create(:oshi, :pending, name: "候補の非公開画像", created_by_user: create(:user))
      hidden = create(:oshi_common_image, oshi: hidden_oshi)
      personal = create(:user_oshi, oshi: named)
      personal.representative_image.attach(io: File.open(Rails.root.join("spec/fixtures/files/image.png")), filename: "private.png", content_type: "image/png")
      get new_oshi_path, params: { q: "候補", suggest: "1" }
      expect(document.css("script")).to be_empty
      expect(document.at_css("[data-oshi-id='#{named.id}'] strong").text).to eq(named.name)
      expect(document.at_css("input[value='#{named.id}']")["data-suggestion-name"]).to eq(named.name)
      expect(document.at_css("[data-oshi-id='#{named.id}'] img")["src"]).to eq(common_oshi_image_path(active.image.attachment))
      expect(document.at_css("[data-oshi-id='#{plain.id}'] img")["src"]).to include("image_placeholder")
      expect(document.text).to include(active.attribution_text, active.license_name)
      expect(response.body).not_to include(inactive.attribution_text, hidden_oshi.name,
        common_oshi_image_path(inactive.image.attachment), common_oshi_image_path(hidden.image.attachment),
        protected_image_path(personal.representative_image.attachment))
      expect(document.css("[role='option'] input, [role='option'] button, [role='option'] a")).to be_empty
    end

    it "preloads bounded suggestion image metadata in at most three SELECTs" do
      10.times { |index| create(:oshi_common_image, oshi: create(:oshi, :approved, name: format("予測画像%02d", index))) }
      queries = []
      subscriber = lambda do |*, payload|
        sql = payload[:sql]
        queries << sql if sql.include?("oshi_common_images") || sql.include?("active_storage_attachments") || sql.include?("active_storage_blobs")
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get new_oshi_path, params: { q: "予測画像", suggest: "1" } }
      expect(document.css("input[name='oshi_id']").size).to eq(8)
      expect(queries.grep(/SELECT/).size).to be <= 3
    end
  end
end
