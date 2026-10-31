require "rails_helper"

RSpec.describe "Japanese form copy and input examples", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }

  def document
    Nokogiri::HTML5(response.body)
  end

  def expect_field(name, label:, example:, value: "")
    node = document.at_css("[name='#{name}']")
    expect(node).to be_present
    expect(document.at_css("label[for='#{node['id']}']").text).to eq(label)
    expect(node["placeholder"]).to eq(example)
    expect(node.name == "textarea" ? node.text : node["value"].to_s).to eq(value)
    expect(response.body).not_to match(/translation[_ ]missing/)
  end

  [ "/users/sign_in", "/users/sign_up" ].each do |path|
    it "keeps Japanese authentication labels and provides an email example at #{path}" do
      get path

      expect(response).to have_http_status(:ok)
      expect_field "user[email]", label: "メールアドレス", example: "例：name@example.com"
      expect(document.css("input[type='password'][placeholder]")).to be_empty
    end
  end

  context "when signed in" do
    before { sign_in user }

    it "adds examples to the activity text fields without replacing values or date constraints" do
      create(:user_oshi, user: user, oshi: create(:oshi, :approved))
      get new_activity_path

      expect_field "activity[title]", label: "タイトル（必須）", example: "例：春のライブツアー"
      expect_field "activity[place]", label: "場所", example: "例：○○ホール"
      expect_field "activity[memo]", label: "メモ", example: "例：アンコールが印象に残りました。"
      expect(document.at_css("input[name='activity[occurred_on]']")["type"]).to eq("date")
      expect(document.css("input[type='date'][placeholder], input[type='file'][placeholder]")).to be_empty
    end

    it "keeps the existing oshi search example and period guidance" do
      get new_oshi_path

      expect_field "oshi[name]", label: "推し名（必須）", example: "例：架空バンドA"
      expect_field "oshi[affiliation]", label: "所属・作品", example: "例：所属グループや作品名"
      expect(document.at_css("input[name='q']")["placeholder"]).to eq("名前・別名・所属・作品で検索")
      expect(document.at_css("#new-period-help").text).to eq("YYYY または YYYY/MMで入力してください（例：2023、2023/05）。")
    end

    it "preserves profile values while adding examples" do
      create(:profile, user: user, display_name: "現在の表示名", introduction: "現在の自己紹介")
      get edit_profile_path

      expect_field "profile[display_name]", label: "表示名（必須）", example: "例：推し活メモ", value: "現在の表示名"
      expect_field "profile[introduction]", label: "自己紹介", example: "例：ライブや配信の感想を記録しています。", value: "現在の自己紹介"
      expect(document.at_css("input[name='profile[display_name]']")["aria-describedby"]).to eq("display-name-help")
    end

    it "provides a subscription name example and retains the stored billing-cycle values" do
      get new_subscription_path

      expect_field "subscription[name]", label: "契約名（必須）", example: "例：ファンクラブ会費"
      options = document.css("select[name='subscription[billing_cycle]'] option").reject { |option| option["value"].empty? }
      expect(options.map { |option| [ option.text, option["value"] ] }).to eq([ [ "月額", "monthly" ], [ "年額", "yearly" ] ])
    end

    it "uses dictionary values for navigation, examples and save notices" do
      original_backend = I18n.backend
      I18n.backend = I18n::Backend::Simple.new
      I18n.backend.eager_load!
      I18n.backend.store_translations(:ja,
        ui: { navigation: { top: "辞書のトップ" }, placeholders: { display_name: "辞書の入力例" } },
        notices: { profiles: { updated: "辞書の保存通知" } })
      get edit_profile_path

      expect(document.at_css("nav a[href='#{root_path}']").text).to eq("辞書のトップ")
      expect(document.at_css("input[name='profile[display_name]']")["placeholder"]).to eq("辞書の入力例")
      patch profile_path, params: { profile: { display_name: "入力した表示名" } }
      expect(response).to redirect_to(my_page_path)
      expect(flash[:notice]).to eq("辞書の保存通知")
      expect(user.reload.profile.display_name).to eq("入力した表示名")
    ensure
      I18n.backend = original_backend
    end
  end

  it "provides rights-information examples to administrators without changing the date or file inputs" do
    sign_in create(:user, :admin)
    oshi = create(:oshi, :approved)
    get new_admin_oshi_common_image_path(oshi_id: oshi.id)

    expect_field "oshi_common_image[source_url]", label: "出典URL（必須）", example: "例：https://example.com/photos/123"
    expect_field "oshi_common_image[creator_name]", label: "作者・権利者（必須）", example: "例：作者A"
    expect_field "oshi_common_image[license_name]", label: "ライセンス・利用許諾（必須）", example: "例：CC BY 4.0"
    expect_field "oshi_common_image[attribution_text]", label: "帰属表示（必須）", example: "例：作品名・作者名・ライセンス名"
    expect_field "oshi_common_image[usage_notes]", label: "利用条件メモ", example: "例：出典表示が必要、改変不可"
    expect(document.css("input[type='datetime-local'][placeholder], input[type='file'][placeholder]")).to be_empty
  end
end
