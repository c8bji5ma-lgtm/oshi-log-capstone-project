require "rails_helper"
require_relative "../../support/image_attachments"

RSpec.describe "Admin oshi merging", type: :request do
  include ImageAttachments

  let(:admin) { create(:user, :admin) }
  let(:user) { create(:user) }
  let(:source) { create(:oshi, :pending, name: "旧名称", created_by_user: user) }
  let(:target) { create(:oshi, :approved, name: "正式名称", affiliation: "所属表示") }

  def sign_in_as(account)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def submit_merge(attributes = {})
    post merge_admin_oshis_path, params: { oshi_merge: { source_id: source.id.to_s, target_id: target.id.to_s }.merge(attributes) }
  end

  def snapshot
    [ Oshi, UserOshi, Activity, ActivityOshi, Subscription, SubscriptionOshi, OshiAlias,
      ActiveStorage::Attachment, ActiveStorage::Blob ].to_h do |model|
      [ model.name, model.order(:id).map(&:attributes) ]
    end
  end

  def prepare_merge
    original = create(:user_oshi, user: user, oshi: source, started_period: "2020/05")
    retained = create(:user_oshi, user: user, oshi: target, started_period: nil)
    original.representative_image.attach(image_upload)
    activity = build(:activity, :without_oshis, user: user, amount: 2500)
    [ source, target ].each { |oshi| activity.activity_oshis.build(oshi: oshi) }
    activity.save!
    activity.images.attach(image_upload("image.jpg"))
    subscription = create(:subscription, user: user, oshis: [ source, target ])
    create(:oshi_alias, oshi: source, alias_name: "旧別名")
    [ original, retained, activity, subscription ]
  end

  def expect_failure_notice(text)
    expect(response).to have_http_status(:see_other)
    expect(response.headers["Location"]).to include(new_merge_admin_oshis_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(document.at_css("[role='alert']").text).to include(text)
    expect(document.at_css("main a[href='#{admin_oshis_path}']")).to be_present
  end

  context "when signed out" do
    it "requires login for the selection screen" do
      get new_merge_admin_oshis_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "requires login before calling the merge service" do
      prepare_merge
      before = snapshot
      expect(Oshis::Merge).not_to receive(:call)
      submit_merge
      expect(response).to redirect_to(new_user_session_path)
      expect(snapshot).to eq(before)
    end
  end

  context "when signed in as a regular user" do
    before { sign_in_as(user) }

    it "refuses the selection screen without exposing candidates" do
      source
      target
      get new_merge_admin_oshis_path
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("管理者権限が必要です。")
      expect(response.body).not_to include(source.name, target.name)
    end

    it "refuses to merge even the user's own oshi without calling the service" do
      prepare_merge
      before = snapshot
      expect(Oshis::Merge).not_to receive(:call)
      submit_merge
      expect(response).to have_http_status(:forbidden)
      expect(snapshot).to eq(before)
    end
  end

  context "when signed in as an admin" do
    before { sign_in_as(admin) }

    it "links from the management screen even when there are no pending oshis" do
      create(:oshi, :approved)
      get admin_oshis_path
      expect(document.at_css("a[href='#{new_merge_admin_oshis_path}']").text).to eq("重複した推しを統合")
    end

    it "searches source and target separately across all statuses and confirms IDs before POST" do
      source
      target
      rejected = create(:oshi, :rejected, name: "旧名称", oshi_type: "声優")
      get new_merge_admin_oshis_path, params: { oshi_merge: {
        source_query: "旧名称", target_query: "正式名称", source_id: rejected.id, target_id: target.id
      } }
      expect(response).to have_http_status(:ok)
      expect(document.at_css("main h1").text).to eq("推しの重複統合")
      expect(document.at_css("#merge-warning").text).to include("統合元の推しは削除されます")
      search_form = document.at_css("form[action='#{new_merge_admin_oshis_path}']")
      expect(search_form["method"]).to eq("get")
      expect(search_form.at_css("input[name='oshi_merge[source_query]']")["value"]).to eq("旧名称")
      source_select = search_form.at_css("select[name='oshi_merge[source_id]']")
      target_select = search_form.at_css("select[name='oshi_merge[target_id]']")
      expect(source_select.css("option[value]").map { |option| option["value"] }.reject(&:empty?))
        .to contain_exactly(source.id.to_s, rejected.id.to_s)
      expect(target_select.css("option[value]").map { |option| option["value"] }.reject(&:empty?)).to eq([ target.id.to_s ])
      expect(source_select.at_css("option[selected]")["value"]).to eq(rejected.id.to_s)
      [ [ rejected, "却下済み" ], [ target, "承認済み" ] ].each do |oshi, status|
        expect(document.at_css("option[value='#{oshi.id}']").text)
          .to include("ID：#{oshi.id}", "名前：#{oshi.name}", "種別：#{oshi.oshi_type}", "状態：#{status}")
      end
      post_form = document.at_css("form[action='#{merge_admin_oshis_path}']")
      expect(post_form["method"]).to eq("post")
      expect(post_form["data-turbo-confirm"]).to include("統合元の推しを削除")
      expect(post_form.at_css("input[name='oshi_merge[source_id]']")["value"]).to eq(rejected.id.to_s)
      expect(post_form.at_css("input[name='oshi_merge[target_id]']")["value"]).to eq(target.id.to_s)
      expect(document.at_css("#merge-selection-heading").parent.text).to include("ID：#{rejected.id}", "ID：#{target.id}")
    end

    it "limits broad candidate searches and preserves selected IDs outside the new result set" do
      records = create_list(:oshi, 52, :approved, name: "大量同名")
      selected_source = records.last
      get new_merge_admin_oshis_path, params: { oshi_merge: {
        source_query: "大量同名", target_query: "見つからない", source_id: selected_source.id, target_id: target.id
      } }

      source_options = document.css("select[name='oshi_merge[source_id]'] option[value]").reject { |option| option["value"].empty? }
      expect(source_options.size).to eq(51)
      expect(source_options.map { |option| option["value"] }).to include(selected_source.id.to_s)
      expect(document.at_css("select[name='oshi_merge[source_id]'] option[selected]")["value"]).to eq(selected_source.id.to_s)
      expect(document.at_css("select[name='oshi_merge[target_id]'] option[selected]")["value"]).to eq(target.id.to_s)
      expect(document.css("[role='status']").map(&:text).join)
        .to include("統合元候補は最大50件", "名前・別名・所属・作品を入力して絞り込んでください")
    end

    [ 0, 1 ].each do |count|
      it "shows an empty state with #{count} candidates and no execution form" do
        create_list(:oshi, count)
        get new_merge_admin_oshis_path
        expect(response).to have_http_status(:ok)
        expect(document.at_css("main").text).to include("推しが2件以上必要です")
        expect(document.css("main form")).to be_empty
      end
    end

    it "uses the existing service to consolidate all references and reports success" do
      original, retained, activity, subscription = prepare_merge
      image_id = original.representative_image.attachment.id
      bytes = original.representative_image.download
      target_attributes = target.attributes
      expect(Oshis::Merge).to receive(:call).with(source_id: source.id.to_s, target_id: target.id.to_s).and_call_original
      submit_merge(status: "rejected", name: "改ざん", return_to: "https://example.com")
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_oshis_path)
      expect(Oshi.exists?(source.id)).to be(false)
      expect(UserOshi.exists?(original.id)).to be(false)
      expect(target.reload.attributes).to eq(target_attributes)
      expect(retained.reload).to have_attributes(started_period: "2020/05")
      expect(retained.representative_image.attachment.id).to eq(image_id)
      expect(retained.representative_image.download).to eq(bytes)
      expect(activity.reload.oshi_ids).to eq([ target.id ])
      expect(subscription.reload.oshi_ids).to eq([ target.id ])
      expect(target.oshi_aliases.pluck(:alias_name)).to contain_exactly("旧名称", "旧別名")
      follow_redirect!
      expect(document.at_css("[role='status']").text).to eq("正式名称に推しを統合しました。")
    end

    it "accepts an approved source and rejected target while retaining the target's state" do
      source.update!(status: :approved)
      target.update!(status: :rejected)
      submit_merge
      expect(response).to redirect_to(admin_oshis_path)
      expect(Oshi.exists?(source.id)).to be(false)
      expect(target.reload).to be_rejected
    end

    [ :source_id, :target_id ].each do |field|
      [ nil, "", "abc", "1x", "-1", "0", [ "1" ], { value: "1" } ].each do |value|
        it "rejects #{field}=#{value.inspect} without changing records" do
          prepare_merge
          before = snapshot
          submit_merge(field => value)
          expect(snapshot).to eq(before)
          expect_failure_notice("正しい推しID")
        end
      end

      it "rejects a missing #{field} even if the candidate was previously displayed" do
        prepare_merge
        get new_merge_admin_oshis_path
        before = snapshot
        submit_merge(field => Oshi.maximum(:id) + 1)
        expect(snapshot).to eq(before)
        expect_failure_notice("対象の推しが見つかりません")
      end
    end

    it "rejects selection of the same oshi on both sides" do
      prepare_merge
      before = snapshot
      submit_merge(target_id: source.id.to_s)
      expect(snapshot).to eq(before)
      expect_failure_notice("別の推しを選択")
    end

    [ nil, "bad shape", [ "1", "2" ], {} ].each do |input|
      it "handles a missing or malformed parameter group #{input.inspect}" do
        prepare_merge
        before = snapshot
        post merge_admin_oshis_path, params: { oshi_merge: input }
        expect(snapshot).to eq(before)
        expect_failure_notice("統合元と統合先")
      end
    end

    it "reports a conflicting period with the user and field and preserves all data" do
      original, retained = prepare_merge
      retained.update!(started_period: "2025")
      before = snapshot
      submit_merge
      expect(snapshot).to eq(before)
      expect_failure_notice("ユーザーID：#{original.user_id}の推し始めが競合")
    end

    it "reports a conflicting representative image without losing either image" do
      original, retained = prepare_merge
      retained.representative_image.attach(image_upload("image.jpg"))
      before = snapshot
      images = [ original.representative_image.download, retained.representative_image.download ]
      submit_merge
      expect(snapshot).to eq(before)
      expect([ original.reload.representative_image.download, retained.reload.representative_image.download ]).to eq(images)
      expect_failure_notice("代表画像が競合")
    end

    it "reports concurrent changes and sends the admin back to select current candidates" do
      prepare_merge
      before = snapshot
      allow(Oshis::Merge).to receive(:call).and_raise(Oshis::Merge::ConcurrentChange, "関連データが変更されました。再度統合を実行してください。")
      submit_merge
      expect(snapshot).to eq(before)
      expect_failure_notice("関連データが変更されました")
    end

    it "rolls back persisted changes after alias validation fails and shows a safe error" do
      original, = prepare_merge
      source.update_column(:name, " ")
      before = snapshot
      image_id = original.representative_image.attachment.id
      bytes = original.representative_image.download
      submit_merge
      expect(snapshot).to eq(before)
      expect(original.reload.representative_image.attachment.id).to eq(image_id)
      expect(original.representative_image.download).to eq(bytes)
      expect_failure_notice("推しを統合できませんでした")
      expect(response.body).not_to include("ActiveRecord::", "Validation failed")
    end

    it "rolls back a late unexpected failure, logs its cause and returns without exposing it" do
      original, = prepare_merge
      before = snapshot
      bytes = original.representative_image.download
      allow_any_instance_of(Oshi).to receive(:destroy!).and_wrap_original do |original_method|
        original_method.call
        expect(Oshi.exists?(source.id)).to be(false)
        raise "private failure details"
      end
      expect(Rails.logger).to receive(:error).with(a_string_including("Oshi merge failed", "private failure details"))
      submit_merge
      expect(snapshot).to eq(before)
      expect(original.reload.representative_image.download).to eq(bytes)
      expect_failure_notice("推しを統合できませんでした")
      expect(response.body).not_to include("private failure details")
    end

    it "refuses a repeated submission after the source has already been merged" do
      prepare_merge
      submit_merge
      before = snapshot
      submit_merge
      expect(snapshot).to eq(before)
      expect_failure_notice("対象の推しが見つかりません")
    end
  end
end
