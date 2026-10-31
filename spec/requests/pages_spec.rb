require "rails_helper"

RSpec.describe "Top and home pages", type: :request do
  let(:user) { create(:user) }

  def document
    Nokogiri::HTML(response.body)
  end

  it "shows the public top with the service concept and authentication links" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css("html")["lang"]).to eq("ja")
    expect(document.at_css("title").text).to eq("トップ | OshiLog")
    expect(document.at_css("main h1").text).to eq("OshiLog")
    expect(document.at_css("main").text).to include("記録する・振り返る・可視化する")
    expect(document.css("main h2").map(&:text)).to eq(%w[記録 振り返り 可視化])
    expect(document.at_css("main a[href='#{new_user_session_path}']").text).to eq("ログイン")
    expect(document.at_css("main a[href='#{new_user_registration_path}']").text).to eq("新規登録")
    expect(document.css("nav a").map(&:text)).to eq(%w[ログイン 新規登録])
    expect(document.at_css("nav a[href='#{oshis_path}']")).to be_nil
    expect(document.at_css("main").text).not_to include("今月の推し活", "18,400", "CANDY TUNE")
  end

  it "requires authentication for the direct home URL" do
    get home_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it "requires authentication for my page" do
    get my_page_path

    expect(response).to redirect_to(new_user_session_path)
  end

  context "when signed in" do
    before do
      post user_session_path, params: { user: { email: user.email, password: "password123" } }
    end

    it "renders useful empty home sections at root without another redirect or sample data" do
      get root_path

      expect(response).to have_http_status(:ok)
      expect(document.at_css("title").text).to eq("ホーム | OshiLog")
      expect(document.at_css("main h1").text).to eq("ホーム")
      expect(document.css("main h2").map(&:text)).to eq(
        [ "最近の記録", "今月の推し活", "登録している推し", "推し活の積み重ね", "今日の気づき" ]
      )
      expect(document.at_css(".home-summary-card").text).to include("活動回数", "0回", "活動支出", "記録なし")
      expect(document.at_css(".home-recent-card").text).to include("記録はまだありません")
      expect(document.at_css(".home-insight-card").text).to include("比較できる記録が増えると")
      continuation = new_oshi_path(continue: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(document.at_css(".home-primary-action")["href"]).to eq(continuation)
      expect(document.at_css(".home-primary-action").text).to eq("最初の推しを登録")
      expect(document.at_css(".home-recent-card a")["href"]).to eq(continuation)
      expect(document.at_css("main").text).not_to include("準備中")
      expect(document.at_css("main").text).not_to include("18,400", "CANDY TUNE", "活動 5回")
      expect(document.css("nav a").map(&:text)).to eq(%w[トップ 推し一覧 活動記録一覧 マイページ])
      expect(document.at_css("header .header-session button").text).to eq("ログアウト")
      expect(document.at_css("nav a[href='#{new_user_session_path}']")).to be_nil
      expect(document.at_css("nav a[href='#{new_user_registration_path}']")).to be_nil
    end

    it "shows only owned non-future activities, current-month totals, oshis and an existing insight" do
      first_oshi = create(:oshi, :approved, name: "青い推し")
      second_oshi = create(:oshi, :approved, name: "星の推し")
      create(:user_oshi, user: user, oshi: first_oshi)
      create(:user_oshi, user: user, oshi: second_oshi)
      previous = build(:activity, :without_oshis, user: user, title: "前期の記録", occurred_on: Date.current.beginning_of_month - 3.months, activity_type: "その他", amount: 9000)
      previous.activity_oshis.build(oshi: first_oshi)
      previous.save!
      recent = build(:activity, :without_oshis, user: user, title: "今月のライブ", occurred_on: Date.current, amount: 2400)
      recent.activity_oshis.build(oshi: first_oshi)
      recent.save!
      future = build(:activity, :without_oshis, user: user, title: "未来の記録", occurred_on: Date.current + 1, amount: 50_000)
      future.activity_oshis.build(oshi: second_oshi)
      future.save!
      other = create(:activity, title: "他人の記録", occurred_on: Date.current, amount: 80_000)

      get home_path

      expect(document.at_css(".home-summary-card").text).to include("1回", "2,400円")
      expect(document.css(".home-oshi-list li").map(&:text)).to eq([ "星の推し", "青い推し" ])
      expect(document.css(".home-recent-list a").map(&:text)).to include(recent.title, previous.title)
      expect(document.at_css(".home-insight-card").text).to include("ライブ・イベント")
      expect(document.at_css(".home-primary-action")["href"]).to eq(new_activity_path)
      expect(document.at_css(".home-primary-action").text).to eq("推し活を記録する")
      expect(document.at_css("main").text).not_to include(future.title, other.title, "50,000", "80,000")
    end

    it "renders the same home content at the direct home URL" do
      get root_path
      root_content = document.at_css("main").to_html

      get home_path

      expect(response).to have_http_status(:ok)
      expect(document.at_css("main").to_html).to eq(root_content)
    end

    it "links from my page to oshi data and profile editing without a form" do
      get my_page_path

      expect(response).to have_http_status(:ok)
      expect(document.at_css("main h1").text).to eq("マイページ")
      expect(document.at_css("main a[href='#{oshi_data_path}']").text).to eq("推し活データを見る")
      expect(document.at_css("main a[href='#{edit_profile_path}']").text).to eq("プロフィール編集")
      expect(document.css("main form")).to be_empty
    end
  end
end
