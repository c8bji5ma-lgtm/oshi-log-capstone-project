require "rails_helper"
require "tmpdir"
require_relative "../support/image_attachments"

RSpec.describe "Admin merging and authorization in the browser", type: :system do
  include ImageAttachments

  let(:admin) { create(:user, :admin) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  def sign_in_as(account)
    visit new_user_session_path
    within("main form") do
      fill_in "user_email", with: account.email
      fill_in "user_password", with: "password123"
      click_button "Log in"
    end
    expect(page).to have_current_path(root_path)
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def sign_out
    click_button "ログアウト"
    expect(page).to have_current_path(new_user_session_path)
    expect(page).to have_button("Log in")
  end

  def open_my_page
    within("nav[aria-label='グローバルナビゲーション']") { click_link "マイページ" }
    expect(page).to have_css("main h1", text: "マイページ", exact_text: true)
  end

  def check_loaded_image(alt)
    expect(page).to have_css("img[alt='#{alt}']", wait: 10) { |image|
      image.evaluate_script("this.complete && this.naturalWidth > 0 && this.naturalHeight > 0")
    }
  end

  context "when merging registered oshis" do
    let(:source) { create(:oshi, :pending, name: "統合元の旧名称", created_by_user: user) }
    let(:target) { create(:oshi, :approved, name: "統合先の正式名称") }
    let(:original) { create(:user_oshi, user: user, oshi: source, started_period: "2020/05", ended_period: "2024") }
    let(:retained) { create(:user_oshi, user: user, oshi: target, started_period: nil) }
    let(:activity) do
      record = build(:activity, :without_oshis, user: user, title: "統合しても残る活動")
      [ source, target ].each { |oshi| record.activity_oshis.build(oshi: oshi) }
      record.tap(&:save!)
    end
    let(:subscription) { create(:subscription, user: user, name: "統合しても残る固定費", oshis: [ source, target ]) }

    around do |example|
      previous_registry = ActiveStorage::Blob.services
      previous_service = ActiveStorage::Blob.service
      Dir.mktmpdir("oshilog-admin-merge-system-") do |directory|
        storage = ActiveStorage::Service::DiskService.new(root: directory)
        storage.name = "test"
        ActiveStorage::Blob.services = { "test" => storage }
        ActiveStorage::Blob.service = storage
        example.run
      ensure
        Capybara.reset_sessions!
      end
    ensure
      ActiveStorage::Blob.services = previous_registry
      ActiveStorage::Blob.service = previous_service
    end

    before do
      original.representative_image.attach(image_upload)
      retained
      activity
      subscription
      create(:oshi_alias, oshi: source, alias_name: "統合元の別名")
    end

    def merge_state
      # Only the scenario's data; lock, transaction and original-file details belong to service specs.
      [ source.reload.attributes, target.reload.attributes, original.reload.attributes, retained.reload.attributes,
        original.representative_image.blob_id, retained.representative_image.blob_id,
        activity.reload.oshi_ids.sort, subscription.reload.oshi_ids.sort,
        OshiAlias.where(oshi_id: [ source.id, target.id ]).order(:id).pluck(:oshi_id, :alias_name) ]
    end

    def open_merge
      open_my_page
      click_link "推し承認管理"
      expect(page).to have_css("main h1", text: "推し承認管理", exact_text: true)
      click_link "重複した推しを統合"
      expect(page).to have_current_path(new_merge_admin_oshis_path, ignore_query: true)
      expect(page).to have_css("main h1", text: "推しの重複統合", exact_text: true)
      expect(page).to have_text("統合元の推しは削除されます。")
      fill_in "統合元を検索", with: source.name
      fill_in "統合先を検索", with: target.name
      click_button "候補を検索・選択内容を確認"
      expect(page).to have_css("select[name='oshi_merge[source_id]'] option[value='#{source.id}']", text: "ID：#{source.id}")
      expect(page).to have_css("select[name='oshi_merge[target_id]'] option[value='#{target.id}']", text: "ID：#{target.id}")
    end

    def select_merge_candidates
      { "統合元（削除する推し）" => source, "統合先（残す推し）" => target }.each do |field, record|
        label = find_field(field).find("option[value='#{record.id}']", visible: :all).text(:all)
        select label, from: field
        expect(page).to have_select(field, selected: label)
      end
      click_button "候補を検索・選択内容を確認"
      expect(page).to have_css("#merge-selection-heading", text: "選択内容", exact_text: true)
      expect(page).to have_text("統合元：ID：#{source.id}")
      expect(page).to have_text("統合先：ID：#{target.id}")
    end

    def confirm_merge
      accept_confirm("統合元の推しを削除して統合します。選択内容は正しいですか？") do
        click_button "選んだ推しを統合"
      end
    end

    def check_preserved_registrations
      sign_out
      sign_in_as(user)
      within("nav[aria-label='グローバルナビゲーション']") { click_link "推し一覧" }
      [ original, retained ].each do |record|
        within("main section.card", text: record.oshi.name) { click_link "詳細", exact: true }
        expect(page).to have_css("main dd", text: record.started_period || "未設定", exact_text: true)
        check_loaded_image("#{record.oshi.name}の代表画像") if record.representative_image.attached?
        click_link "推し一覧へ戻る"
      end
    end

    it "cancels without changing data, then confirms the merge and shows inherited information to the owner" do
      before = merge_state
      sign_in_as(admin)
      open_merge
      select_merge_candidates
      dismiss_confirm("統合元の推しを削除して統合します。選択内容は正しいですか？") do
        click_button "選んだ推しを統合"
      end
      expect(page).to have_current_path(new_merge_admin_oshis_path, ignore_query: true)
      expect(page).to have_button("選んだ推しを統合", disabled: false)
      expect(merge_state).to eq(before)
      select_merge_candidates
      confirm_merge
      expect(page).to have_current_path(admin_oshis_path)
      expect(page).to have_css("[role='status']", text: "#{target.name}に推しを統合しました。")
      expect(page).not_to have_css("main h2", text: source.name, exact_text: true)
      expect(Oshi.exists?(source.id)).to be(false)
      expect(target.oshi_aliases.pluck(:alias_name)).to contain_exactly(source.name, "統合元の別名")

      sign_out
      sign_in_as(user)
      within("nav[aria-label='グローバルナビゲーション']") { click_link "推し一覧" }
      expect(page).to have_css("main section.card", count: 1)
      expect(page).to have_css("main h2", text: target.name, exact_text: true)
      expect(page).not_to have_css("main h2", text: source.name, exact_text: true)
      within("main section.card", text: target.name) { click_link "詳細", exact: true }
      expect(page).to have_current_path(user_oshi_path(retained))
      expect(page).to have_css("main dd", text: "2020/05", exact_text: true)
      expect(page).to have_css("main dd", text: "2024", exact_text: true)
      check_loaded_image("#{target.name}の代表画像")
      within("nav[aria-label='グローバルナビゲーション']") { click_link "活動記録一覧" }
      click_link activity.title
      expect(page).to have_css("main dd", text: target.name, exact_text: true)
      expect(page).not_to have_text(source.name)
      open_my_page
      click_link "推し活データを見る"
      click_link "固定費を管理する"
      within("main section.card", text: subscription.name) do
        expect(page).to have_css("dd", text: target.name, exact_text: true)
        expect(page).not_to have_text(source.name)
      end
    end

    { period: "推し始め", image: "代表画像" }.each do |conflict, label|
      it "shows the #{label} conflict and preserves the candidates and owner data" do
        if conflict == :period
          retained.update!(started_period: "2025")
        else
          retained.representative_image.attach(image_upload("image.jpg"))
        end
        before = merge_state
        sign_in_as(admin)
        open_merge
        select_merge_candidates
        confirm_merge
        expect(page).to have_current_path(new_merge_admin_oshis_path, ignore_query: true)
        expect(page).to have_css("[role='alert']", text: "ユーザーID：#{user.id}の#{label}が競合するため、統合を中止しました。登録内容を確認してください。")
        expect(page).to have_button("選んだ推しを統合")
        expect(merge_state).to eq(before)
        check_preserved_registrations
      end
    end
  end

  it "shows the forbidden page for regular users opening admin URLs and requires login after logout" do
    candidate = create(:oshi, :pending, name: "管理画面だけの申請候補", created_by_user: other_user)
    sign_in_as(user)
    open_my_page
    expect(page).not_to have_link("推し承認管理")
    [ admin_oshis_path, new_merge_admin_oshis_path ].each do |path|
      visit path
      expect(page).to have_current_path(path)
      expect(page).to have_title("アクセスできません | OshiLog", exact: true)
      expect(page).to have_css("main h1", text: "アクセスできません", exact_text: true)
      expect(page).to have_text("管理者権限が必要です。")
      expect(page).not_to have_text(candidate.name)
      expect(page).not_to have_button("選んだ推しを統合")
      click_link "ホームへ戻る"
      expect(page).to have_current_path(home_path)
    end
    sign_out
    visit new_merge_admin_oshis_path
    expect(page).to have_current_path(new_user_session_path)
    expect(page).to have_css("[role='alert']", text: "続けるにはログインしてください。")
    expect(page).to have_button("Log in")
  end

  it "shows identical not-found pages for foreign and missing records after an actual user switch" do
    registration = create(:user_oshi, user: other_user, oshi: create(:oshi, :approved, name: "所有者の登録済み推し"))
    activity = build(:activity, :without_oshis, user: other_user, title: "所有者だけの活動", memo: "所有者だけのメモ")
    activity.activity_oshis.build(oshi: registration.oshi)
    activity.save!
    subscription = create(:subscription, user: other_user, name: "所有者だけの固定費", oshis: [ registration.oshi ])
    sign_in_as(other_user)
    visit activity_path(activity)
    expect(page).to have_css("main h2", text: activity.title, exact_text: true)
    visit user_oshi_path(registration)
    expect(page).to have_css("main dd", text: registration.oshi.name, exact_text: true)
    sign_out
    sign_in_as(user)

    [ [ activity_path(activity), activity_path(id: Activity.maximum(:id) + 1) ],
      [ edit_activity_path(activity), edit_activity_path(id: Activity.maximum(:id) + 1) ],
      [ user_oshi_path(registration), user_oshi_path(id: UserOshi.maximum(:id) + 1) ],
      [ edit_user_oshi_path(registration), edit_user_oshi_path(id: UserOshi.maximum(:id) + 1) ],
      [ edit_subscription_path(subscription), edit_subscription_path(id: Subscription.maximum(:id) + 1) ] ].each do |paths|
      contents = paths.map do |path|
        visit path
        expect(page).to have_current_path(path)
        expect(page).to have_title("ページが見つかりません | OshiLog", exact: true)
        expect(page).to have_css("main h1", text: "ページが見つかりません", exact_text: true)
        expect(page).to have_link("ホームへ戻る", href: home_path)
        [ activity.title, activity.memo, registration.oshi.name, subscription.name, "ActiveRecord::", "Couldn't find" ].each do |private_text|
          expect(page).not_to have_text(private_text)
        end
        find("main").text
      end
      expect(contents.first).to eq(contents.last)
    end
    sign_out
    visit activity_path(activity)
    expect(page).to have_current_path(new_user_session_path)
    expect(page).to have_css("[role='alert']", text: "続けるにはログインしてください。")
    expect(page).to have_field("user_email")
    expect(page).not_to have_text(activity.title)
  end
end
