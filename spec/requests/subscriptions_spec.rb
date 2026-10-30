require "rails_helper"

RSpec.describe "Subscription management", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:record) { create(:subscription, user: user) }
  let(:attributes) { { name: "ファンクラブ", amount: "1000", billing_cycle: "monthly", started_on: "2026-01-01", ended_on: "2026-12-31" } }

  def document
    Nokogiri::HTML(response.body)
  end

  def expect_amount_guidance(invalid: false)
    message = "月額なら1か月分、年額なら1年分の金額を入力してください。"
    expect(I18n.t("ui.subscription.amount_help", locale: :ja, raise: true)).to eq(message)
    expect(document.css("#subscription-amount-help").size).to eq(1)
    expect(document.at_css("#subscription-amount-help").text).to eq(message)
    amount = document.at_css("#subscription_amount")
    expect(amount["aria-describedby"].split).to eq([ "subscription-amount-help" ])
    expect(document.css("[aria-describedby~='subscription-amount-help']").map { |node| node["id"] }).to eq([ "subscription_amount" ])
    expect(document.css("label[for='subscription_amount']").map(&:text)).to eq([ "金額（円・必須）" ])
    expect(%w[required min step].map { |key| amount[key] }).to eq([ "required", "0", "1" ])
    expect(amount["aria-invalid"]).to eq(invalid.to_s)
    expect(document.at_css("#subscription_oshi_ids")["aria-describedby"]).to eq("subscription-oshi-help")
    expect(response.body).not_to include("translation_missing")
  end

  def oshi_choices
    document.css("#subscription_oshi_ids input[type='checkbox'][name='subscription[oshi_ids][]']")
  end

  def form_oshi_ids
    oshi_choices.select { |input| input["checked"] }.map { |input| input["value"].to_i }
  end

  def login
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def owned_oshi(status: "approved", ended: false)
    oshi = create(:oshi, status: status, created_by_user: user)
    create(:user_oshi, user: user, oshi: oshi, ended_period: ended ? "2025/01" : nil)
    oshi
  end

  def versioned(subscription, parameters)
    parameters.merge(lock_version: subscription.lock_version.to_s)
  end

  [ [ :get, "/subscriptions" ], [ :get, "/subscriptions/new" ], [ :post, "/subscriptions" ],
    [ :get, "/subscriptions/1/edit" ], [ :patch, "/subscriptions/1" ], [ :put, "/subscriptions/1" ], [ :delete, "/subscriptions/1" ] ].each do |method, path|
    it "requires authentication for #{method} #{path}" do
      public_send(method, path)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context "when signed in" do
    before { login }

    [ {}, { subscription: nil }, { subscription: {} }, { subscription: "invalid" },
      { subscription: [ "invalid" ] }, { subscription: false } ].each do |parameters|
      it "returns 400 on create and update for #{parameters.inspect} without changing records or links" do
        record.update!(oshis: [ owned_oshi ])
        original = record.attributes
        links = record.subscription_oshis.order(:id).pluck(:id, :oshi_id)
        counts = [ Subscription.count, SubscriptionOshi.count ]

        post subscriptions_path, params: parameters, as: :json
        expect(response).to have_http_status(:bad_request)
        expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
        patch subscription_path(record), params: parameters, as: :json
        expect(response).to have_http_status(:bad_request)
        expect(record.reload.attributes).to eq(original)
        expect(record.subscription_oshis.order(:id).pluck(:id, :oshi_id)).to eq(links)
        expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
      end
    end

    it "lists every owned contract in descending creation and ID order with actions and status" do
      travel_to(Time.zone.local(2026, 10, 6, 12)) do
        oshi = owned_oshi
        older = create(:subscription, user: user, name: "古い契約", created_at: 1.day.ago)
        active = create(:subscription, user: user, name: "有効契約", oshis: [ oshi ], started_on: Date.current, ended_on: Date.current)
        ended = create(:subscription, :yearly, user: user, name: "終了契約", ended_on: Date.current - 1, created_at: active.created_at)
        future = create(:subscription, user: user, name: "未来契約", started_on: Date.current + 1, created_at: active.created_at)
        create(:subscription, user: other, name: "他人の秘密")
        get subscriptions_path
        expect(response).to have_http_status(:ok)
        cards = document.css("main section.card")
        expect(cards.map { |card| card.at_css("h2").text }).to eq([ future.name, ended.name, active.name, older.name ])
        expect(response.body).not_to include("他人の秘密")
        expect(cards[2].text).to include("1,000円", "月額", oshi.name, "2026/10/06", "有効")
        expect(cards[1].text).to include("年額", "指定なし", "2026/10/05", "無効")
        expect(cards[0].text).to include("無効")
        expect(document.at_css("a[href='#{new_subscription_path}']")).to be_present
        expect(document.at_css("a[href='#{edit_subscription_path(active)}']")).to be_present
        delete_form = document.at_css("form[action='#{subscription_path(active)}']")
        expect(delete_form["data-turbo-confirm"]).to eq("この固定費を削除しますか？")
        expect(delete_form.at_css("input[name='_method']")["value"]).to eq("delete")
      end
    end


    it "shows an optional empty chooser without exposing public unregistered or another user's private oshis" do
      public_only = create(:oshi, :approved, name: "共通カタログだけ")
      private_only = create(:oshi, name: "他人の非公開の推し", created_by_user: other, status: "pending")
      create(:user_oshi, user: other, oshi: private_only)
      get new_subscription_path
      expect(response).to have_http_status(:ok)
      expect(oshi_choices).to be_empty
      expect(document.css("input[type='hidden'][name='subscription[oshi_ids][]']").map { |input| input["value"] }).to eq([ "" ])
      expect(document.at_css("#subscription_oshi_ids").text).to include("登録済みの推しはありません。指定なしで保存できます。")
      expect(response.body).not_to include(public_only.name, private_only.name)
      expect_amount_guidance
    end

    it "escapes personal choice labels and keeps the checked ID without creating a registration" do
      named = create(:oshi, :approved, name: "<script data-choice-injection>危険な名前</script>")
      create(:user_oshi, user: user, oshi: named)
      record.update!(oshis: [ named ])
      count = UserOshi.count
      get edit_subscription_path(record)
      expect(response).to have_http_status(:ok)
      expect(form_oshi_ids).to eq([ named.id ])
      expect(document.at_css("label[for='subscription_oshi_ids_#{named.id}'] span").text).to eq(named.name)
      expect(document.css("script[data-choice-injection]")).to be_empty
      expect(UserOshi.count).to eq(count)
    end

    it "shows an empty state" do
      get subscriptions_path
      expect(response.body).to include("固定費はまだ登録されていません。")
    end

    it "provides the ordered accessible form with only registered oshis and enum choices", :subscription_amount_guidance do
      oshis = [ owned_oshi, owned_oshi(status: "pending"), owned_oshi(status: "rejected"), owned_oshi(ended: true) ]
      create(:oshi, status: "approved")
      get new_subscription_path
      expect(response).to have_http_status(:ok)
      scalar_labels = document.css("main label").reject { |label| label["for"].start_with?("subscription_oshi_ids_") }
      expect(scalar_labels.map { |label| label["for"] }).to eq(%w[subscription_name subscription_amount subscription_billing_cycle subscription_started_on subscription_ended_on])
      expect(document.at_css("fieldset#subscription_oshi_ids legend").text).to eq("対象の推し（任意）")
      expect(oshi_choices.map { |input| input["value"].to_i }).to eq(oshis.sort_by { |oshi| [ oshi.name, oshi.id ] }.map(&:id))
      expect(oshi_choices).to all(satisfy { |input| input["required"].nil? })
      expect(document.css("input[type='hidden'][name='subscription[oshi_ids][]']").map { |input| input["value"] }).to eq([ "" ])
      expect(document.at_css("#subscription-oshi-status")["hidden"]).not_to be_nil
      expect(document.at_css("#subscription-oshi-status").text).to eq("指定なし（0人）")
      expect(document.at_css("#subscription_oshi_ids details summary").text).to eq("推しを選ぶ")
      expect(%w[required min step].map { |key| document.at_css("#subscription_amount")[key] }).to eq([ "required", "0", "1" ])
      expect(document.css("#subscription_billing_cycle option").map(&:text)).to eq([ "選択してください", "月額", "年額" ])
      expect(document.css("#subscription_started_on[required], #subscription_ended_on[required]")).to be_empty
      expect(response.body).to include("対象の推しは任意です。複数選択できます。")
      expect_amount_guidance
    end

    [ "monthly", "yearly" ].each do |cycle|
      it "creates #{cycle} with dates and zero yen, ignoring a forged owner", :subscription_amount_guidance do
        expect do
          post subscriptions_path, params: { subscription: attributes.merge(billing_cycle: cycle, amount: "0", user_id: other.id) }
        end.to change(user.subscriptions, :count).by(1)
        saved = user.subscriptions.last
        expect(saved).to have_attributes(amount: 0, billing_cycle: cycle, started_on: Date.new(2026, 1, 1), ended_on: Date.new(2026, 12, 31))
        expect(saved.oshis).to be_empty
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(subscriptions_path)
        follow_redirect!
        expect(document.at_css(".flash-notice").text).to eq("固定費を登録しました。")
      end
    end

    [ 0, 1, 2 ].each do |count|
      it "creates with #{count} oshis and normalizes blank and duplicate selections" do
        ids = Array.new(count) { owned_oshi.id.to_s }
        post subscriptions_path, params: { subscription: attributes.merge(oshi_ids: [ "" ] + ids + ids) }
        expect(response).to redirect_to(subscriptions_path)
        expect(user.subscriptions.last.oshi_ids).to match_array(ids.map(&:to_i))
      end
    end

    [ "pending", "rejected", "ended" ].each do |state|
      it "creates and updates with a registered #{state} oshi" do
        oshi = owned_oshi(status: state == "ended" ? "approved" : state, ended: state == "ended")
        post subscriptions_path, params: { subscription: attributes.merge(oshi_ids: [ oshi.id.to_s ]) }
        expect(response).to redirect_to(subscriptions_path)
        saved = user.subscriptions.last
        patch subscription_path(saved), params: { subscription: versioned(saved, attributes.merge(name: "更新", oshi_ids: [ oshi.id.to_s ])) }
        expect(response).to redirect_to(subscriptions_path)
        expect(saved.reload.oshi_ids).to eq([ oshi.id ])
      end
    end

    [ "approved", "pending", "rejected" ].each do |status|
      it "rejects an unregistered #{status} oshi without trimming an allowed selection" do
        allowed = owned_oshi
        forbidden = create(:oshi, status: status, created_by_user: other)
        create(:user_oshi, user: other, oshi: forbidden)
        counts = [ Subscription.count, SubscriptionOshi.count ]
        post subscriptions_path, params: { subscription: attributes.merge(oshi_ids: [ allowed.id.to_s, forbidden.id.to_s ]) }
        expect(response).to have_http_status(:unprocessable_content)
        expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
        expect(document.at_css(".validation-errors").text).to include("登録済みの推し")
      end
    end

    [ "1", { bad: "1" }, [ [ "1" ] ], false, nil, [ "invalid" ], [ "1oops" ], [ "0" ], [ "-1" ], [ 1 ] ].each do |ids|
      it "rejects malformed IDs #{ids.inspect} in create and update" do
        record
        original = record.attributes
        counts = [ Subscription.count, SubscriptionOshi.count ]
        post subscriptions_path, params: { subscription: attributes.merge(oshi_ids: ids) }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(oshi_ids: ids)) }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(record.reload.attributes).to eq(original)
        expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
      end
    end

    [ { name: "" }, { amount: "" }, { amount: "-1" }, { amount: "1.5" }, { amount: "invalid" }, { billing_cycle: "weekly" } ].each do |invalid|
      it "rejects #{invalid.inspect} with form errors and no parent", :subscription_amount_guidance do
        expect do
          post subscriptions_path, params: { subscription: attributes.merge(invalid) }
        end.not_to change(Subscription, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css(".validation-errors[role='alert']")).to be_present
        expect(document.css("[aria-invalid='true']")).not_to be_empty
        expect_amount_guidance(invalid: invalid.key?(:amount))
      end
    end

    it "renders edit and updates all scalar fields and A,B to B,C with a retained join", :subscription_amount_guidance do
      a, b, c = Array.new(3) { owned_oshi }
      record.subscription_oshis.create!(oshi: a)
      retained = record.subscription_oshis.create!(oshi: b).id
      get edit_subscription_path(record)
      expect(response).to have_http_status(:ok)
      expect_amount_guidance
      expect(form_oshi_ids).to match_array([ a.id, b.id ])
      expect(document.at_css("#subscription-oshi-status").text).to eq("2人を選択中")
      expect(document.at_css("input[name='subscription[lock_version]']")["value"]).to eq(record.lock_version.to_s)
      patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(name: "更新契約", amount: "2000", billing_cycle: "yearly", user_id: other.id, oshi_ids: [ b.id.to_s, c.id.to_s ])) }
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(subscriptions_path)
      expect(record.reload).to have_attributes(name: "更新契約", amount: 2000, billing_cycle: "yearly", user_id: user.id, started_on: Date.new(2026, 1, 1), ended_on: Date.new(2026, 12, 31))
      expect(record.oshi_ids).to match_array([ b.id, c.id ])
      expect(record.subscription_oshis.find_by!(oshi: b).id).to eq(retained)
      follow_redirect!
      expect(document.at_css(".flash-notice").text).to eq("固定費を更新しました。")
    end

    it "allows clearing every link and changing yearly back to monthly with inverted dates" do
      record.update!(billing_cycle: "yearly", oshis: [ owned_oshi ])
      patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(oshi_ids: [ "" ], started_on: "2027-01-01", ended_on: "2026-01-01")) }
      expect(response).to redirect_to(subscriptions_path)
      expect(record.reload.oshi_ids).to be_empty
      expect(record.billing_cycle).to eq("monthly")
      expect(record.started_on).to be > record.ended_on
      patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(oshi_ids: [ owned_oshi.id.to_s ])) }
      expect(record.reload.oshi_ids.size).to eq(1)
    end

    it "rejects forbidden IDs on update and retains all existing values and joins" do
      original = record.attributes
      join = record.subscription_oshis.create!(oshi: owned_oshi)
      patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(oshi_ids: [ create(:oshi).id.to_s ])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(record.reload.attributes).to eq(original)
      expect(record.subscription_oshis.pluck(:id)).to eq([ join.id ])
    end

    it "retains persisted values and joins but redisplays submitted inputs after invalid update", :subscription_amount_guidance do
      join = record.subscription_oshis.create!(oshi: owned_oshi)
      replacement = owned_oshi
      original = record.attributes
      patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(name: "", amount: "2000", oshi_ids: [ replacement.id.to_s ])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(record.reload.attributes).to eq(original)
      expect(record.subscription_oshis.pluck(:id)).to eq([ join.id ])
      expect(document.at_css("#subscription_amount")["value"]).to eq("2000")
      expect_amount_guidance
      expect(form_oshi_ids).to eq([ replacement.id ])
      expect(document.at_css("#subscription-oshi-status").text).to eq("1人を選択中")
      expect(document.at_css("input[name='subscription[lock_version]']")["value"]).to eq(record.lock_version.to_s)
    end

    it "rolls back create and update and displays a failed join's errors" do
      oshi = owned_oshi
      record
      original = record.attributes
      counts = [ Subscription.count, SubscriptionOshi.count ]
      allow_any_instance_of(SubscriptionOshi).to receive(:save!).and_wrap_original do |original_save|
        link = original_save.receiver
        link.errors.add(:base, "関連保存失敗")
        raise ActiveRecord::RecordInvalid, link
      end
      post subscriptions_path, params: { subscription: attributes.merge(oshi_ids: [ oshi.id.to_s ]) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css(".validation-errors").text).to include("関連保存失敗")
      patch subscription_path(record), params: { subscription: versioned(record, attributes.merge(oshi_ids: [ oshi.id.to_s ])) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(record.reload.attributes).to eq(original)
      expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
    end

    it "renders the submitted values and latest values with 409 when the edit version is stale", :subscription_amount_guidance do
      first, second = Array.new(2) { owned_oshi }
      record.update!(name: "最初の内容", oshis: [ first ])
      stale_version = record.lock_version
      Subscriptions::Save.call(subscription: Subscription.find(record.id), attributes: { name: "先に保存した内容", amount: 3000 },
        oshi_ids: [ second.id ], expected_lock_version: stale_version)

      patch subscription_path(record), params: { subscription: attributes.merge(name: "古い画面の入力", amount: "999",
        oshi_ids: [ first.id.to_s ], lock_version: stale_version.to_s) }

      expect(response).to have_http_status(:conflict)
      expect_amount_guidance
      expect(document.at_css("#subscription_name")["value"]).to eq("古い画面の入力")
      expect(form_oshi_ids).to eq([ first.id ])
      expect(document.at_css("#subscription_oshi_ids details")["open"]).not_to be_nil
      expect(document.at_css("input[name='subscription[lock_version]']")["value"]).to eq(stale_version.to_s)
      expect(document.at_css(".conflict-summary").text).to include("先に保存した内容", second.name)
      expect(document.at_css(".conflict-summary a")["href"]).to eq(edit_subscription_path(record))
      expect(document.at_css(".validation-errors").text).to include("別の画面で更新")
      expect(record.reload).to have_attributes(name: "先に保存した内容", amount: 3000)
      expect(record.oshi_ids).to eq([ second.id ])
    end

    [ nil, "", "1.0", "-1", "01", "2147483648" ].each do |invalid_version|
      it "returns 400 and does not save an invalid edit version #{invalid_version.inspect}" do
        original = record.attributes
        patch subscription_path(record), params: { subscription: attributes.merge(name: "送信値", lock_version: invalid_version) }
        expect(response).to have_http_status(:bad_request)
        expect(document.at_css("#subscription_name")["value"]).to eq("送信値")
        expect(document.at_css(".validation-errors").text).to include("編集情報が不正")
        expect(document.at_css(".conflict-summary a")["href"]).to eq(edit_subscription_path(record))
        expect(record.reload.attributes).to eq(original)
      end
    end

    [ :get, :patch, :put, :delete ].each do |method|
      it "returns 404 for another user's contract via #{method}" do
        foreign = create(:subscription, user: other, oshis: [ create(:oshi) ])
        original = foreign.attributes
        joins = foreign.subscription_oshis.pluck(:id)
        path = method == :get ? edit_subscription_path(foreign) : subscription_path(foreign)
        public_send(method, path, params: { subscription: attributes })
        expect(response).to have_http_status(:not_found)
        expect(foreign.reload.attributes).to eq(original)
        expect(foreign.subscription_oshis.pluck(:id)).to eq(joins)
      end
    end

    it "deletes only the owned contract and all its joins, preserving oshis and user registrations" do
      oshis = Array.new(2) { owned_oshi }
      record.update!(oshis: oshis)
      record.update!(name: "版更新後の削除対象")
      expect(record.lock_version).to be_positive
      foreign = create(:subscription, user: other, oshis: [ oshis.first ])
      counts = [ Oshi.count, UserOshi.count ]
      delete subscription_path(record)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(subscriptions_path)
      expect(Subscription.exists?(record.id)).to be(false)
      expect(SubscriptionOshi.where(subscription_id: record.id)).to be_empty
      expect(foreign.reload.oshi_ids).to eq([ oshis.first.id ])
      expect([ Oshi.count, UserOshi.count ]).to eq(counts)
      follow_redirect!
      expect(document.at_css(".flash-notice").text).to eq("固定費を削除しました。")
    end

    it "restores joins if parent destruction fails" do
      record.update!(oshis: [ owned_oshi ])
      ids = record.subscription_oshis.pluck(:id)
      allow_any_instance_of(Subscription).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)
      delete subscription_path(record)
      expect(response).to redirect_to(subscriptions_path)
      expect(record.reload.subscription_oshis.pluck(:id)).to eq(ids)
      follow_redirect!
      expect(document.at_css(".flash-alert").text).to eq("固定費を削除できませんでした。")
    end
  end
end
