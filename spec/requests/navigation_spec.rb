require "rails_helper"

RSpec.describe "Global navigation and feature destinations", type: :request do
  let(:user) { create(:user) }

  def document
    Nokogiri::HTML(response.body)
  end

  context "when signed out" do
    [ "/", "/users/sign_in", "/users/sign_up" ].each do |path|
      it "shows the shared public navigation at #{path}" do
        get path

        expect(response).to have_http_status(:ok)
        expect(document.at_css("header > div > a[href='#{root_path}']").text).to eq("OshiLog")
        expect(document.at_css("nav")["aria-label"]).to eq("グローバルナビゲーション")
        expect(document.css("nav a").map { |link| [ link.text, link["href"] ] }).to eq(
          [ [ "ログイン", new_user_session_path ], [ "新規登録", new_user_registration_path ] ]
        )
        expect(document.css("nav button")).to be_empty
      end
    end

    [ "/users/sign_in", "/users/sign_up" ].each do |path|
      it "marks the current authentication page at #{path}" do
        get path

        expect(document.css("nav a[aria-current='page']").map { |link| link["href"] }).to eq([ path ])
      end
    end

    [ "/oshis", "/activities", "/activities/new", "/data", "/profile/edit" ].each do |path|
      it "requires authentication at #{path}" do
        get path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    it "does not render empty flash elements" do
      get root_path

      expect(document.css(".flash, [role='status'], [role='alert']")).to be_empty
    end

    it "shows a Devise login failure alert once between the header and main" do
      post user_session_path, params: { user: { email: user.email, password: "incorrect" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.css("[role='alert']").size).to eq(1)
      expect(document.at_css("header + [role='alert'] + main")).to be_present
      expect(document.at_css("[role='alert']").text).to eq(
        I18n.t("devise.failure.invalid", authentication_keys: User.human_attribute_name(:email).downcase)
      )
      expect(document.css("[role='status']")).to be_empty
    end
  end

  context "when signed in" do
    before do
      post user_session_path, params: { user: { email: user.email, password: "password123" } }
    end

    it "links the implemented data page to fixed costs without changing the profile page" do
      get oshi_data_path
      expect(document.at_css("main a[href='#{subscriptions_path}']").text).to eq("固定費を管理する")
      expect(document.at_css("main").text).not_to include("準備中")
      get edit_profile_path
      expect(document.css("main a[href='#{subscriptions_path}']")).to be_empty
    end

    it "shows a Devise login notice once between the header and main" do
      follow_redirect!

      expect(document.css("[role='status']").size).to eq(1)
      expect(document.at_css("header + [role='status'] + main")).to be_present
      expect(document.at_css("[role='status']").text).to eq(I18n.t("devise.sessions.signed_in"))
      expect(document.css("[role='alert']")).to be_empty

      get root_path
      expect(document.css(".flash")).to be_empty
    end

    {
      "/" => "/", "/home" => "/", "/oshis" => "/oshis",
      "/activities" => "/activities", "/my_page" => "/my_page"
    }.each do |path, current_path|
      it "shows the formal navigation and current location at #{path}" do
        get path

        expect(response).to have_http_status(:ok)
        expect(document.css("nav a").map { |link| [ link.text, link["href"] ] }).to eq(
          [ [ "トップ", root_path ], [ "推し一覧", oshis_path ],
            [ "活動記録一覧", activities_path ], [ "マイページ", my_page_path ] ]
        )
        expect(document.css("nav a[aria-current='page']").map { |link| link["href"] }).to eq([ current_path ])
        form = document.at_css("nav form")
        expect(form["action"]).to eq(destroy_user_session_path)
        expect(form["method"]).to eq("post")
        expect(form.at_css("input[name='_method']")["value"]).to eq("delete")
        expect(form.at_css("button").text).to eq("ログアウト")
      end
    end

    it "links my page to the implemented protected profile editor" do
      get my_page_path
      expect(document.at_css("main a[href='#{edit_profile_path}']").text).to eq("プロフィール編集")
      get edit_profile_path

      expect(response).to have_http_status(:ok)
      expect(document.at_css("main h1").text).to eq("プロフィール編集")
      expect(document.at_css("title").text).to eq("プロフィール編集 | OshiLog")
      expect(document.at_css("main").text).not_to include("準備中")
      expect(document.at_css("main form")["action"]).to eq(profile_path)
    end

    it "links my page to the implemented protected data page" do
      get my_page_path
      expect(document.at_css("main a[href='#{oshi_data_path}']").text).to eq("推し活データを見る")
      get oshi_data_path
      expect(response).to have_http_status(:ok)
      expect(document.at_css("main h1").text).to eq("推し活データ")
      expect(document.at_css("title").text).to eq("推し活データ | OshiLog")
      expect(document.at_css("main").text).not_to include("準備中")
    end

    { "/activities" => "活動記録一覧", "/activities/new" => "活動記録を登録" }.each do |path, title|
      it "renders the implemented activity page at #{path}" do
        create(:user_oshi, user: user, oshi: create(:oshi, :approved)) if path == new_activity_path
        get path

        expect(response).to have_http_status(:ok)
        expect(document.at_css("main h1").text).to eq(title)
        expect(document.at_css("title").text).to eq("#{title} | OshiLog")
        expect(document.at_css("main").text).not_to include("準備中")
        expect(document.at_css("main form")).to be_present
      end
    end

    it "links from the activity list to recording an activity" do
      get activities_path

      expect(document.at_css("main a[href='#{new_activity_path}']").text).to eq("記録する")
    end

    it "does not let query parameters replace the oshi list content" do
      get oshis_path, params: { feature: "<script>alert(1)</script>", title: "偽の画面" }

      expect(response).to have_http_status(:ok)
      expect(document.at_css("main h1").text).to eq("推し一覧")
      expect(document.at_css("main").text).not_to include("alert(1)", "偽の画面")
      expect(document.css("main script")).to be_empty
    end
  end
end
