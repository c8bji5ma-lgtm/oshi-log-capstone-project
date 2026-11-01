require "rails_helper"

RSpec.describe "User authentication", type: :request do
  let(:password) { "password123" }

  def register_user(attributes = {})
    post user_registration_path, params: {
      user: { email: "new@example.com", password: password,
              password_confirmation: password }.merge(attributes)
    }
  end

  it "allows access to the sign-in and sign-up pages without authentication" do
    get new_user_session_path
    expect(response).to have_http_status(:ok)
    sign_in_page = Nokogiri::HTML(response.body)
    expect(sign_in_page.at_css("main h1").text).to eq("ログイン")
    expect(sign_in_page.css("main label").map(&:text)).to include("メールアドレス", "パスワード")
    expect(sign_in_page.at_css("main input[type='submit']")["value"]).to eq("ログイン")

    get new_user_registration_path
    expect(response).to have_http_status(:ok)
    sign_up_page = Nokogiri::HTML(response.body)
    expect(sign_up_page.at_css("main h1").text).to eq("新規登録")
    expect(sign_up_page.css("main label").map(&:text))
      .to include("メールアドレス", "パスワード", "パスワード（確認用）")
    expect(sign_up_page.at_css("main input[type='submit']")["value"]).to eq("登録する")
    expect(response.body).not_to include("Sign up", "characters minimum")
  end

  it "registers a user and redirects to root showing the home page" do
    expect { register_user }.to change(User, :count).by(1)
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("main h1").text).to eq("ホーム")
  end

  it "does not allow registration to grant admin privileges" do
    register_user(admin: true)
    expect(User.find_by!(email: "new@example.com").admin?).to be(false)
  end

  it "rejects invalid registration attributes" do
    expect { register_user(password_confirmation: "different") }.not_to change(User, :count)
    expect(response).to have_http_status(:unprocessable_content)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("[role='alert']").text).to include("パスワード（確認用）と入力内容が一致しません")
    expect(document.at_css("input[name='user[email]']")["value"]).to eq("new@example.com")
  end

  it "signs in with valid credentials and redirects to root showing the home page" do
    user = create(:user, password: password)
    post user_session_path, params: { user: { email: user.email, password: password } }
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("main h1").text).to eq("ホーム")
  end

  it "returns to the stored destination after signing in" do
    user = create(:user, password: password)
    get my_page_path
    expect(response).to redirect_to(new_user_session_path)

    post user_session_path, params: { user: { email: user.email, password: password } }
    expect(response).to redirect_to(my_page_path)
    follow_redirect!
    expect(Nokogiri::HTML(response.body).at_css("main h1").text).to eq("マイページ")
  end

  it "rejects invalid login credentials" do
    user = create(:user)
    post user_session_path, params: { user: { email: user.email, password: "incorrect" } }
    expect(response).to have_http_status(:unprocessable_content)
    get home_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "signs out via DELETE and prevents further protected access" do
    user = create(:user, password: password)
    post user_session_path, params: { user: { email: user.email, password: password } }
    delete destroy_user_session_path
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(new_user_session_path)
    follow_redirect!
    expect(Nokogiri::HTML(response.body).at_css("[role='status']").text).to eq(I18n.t("devise.sessions.signed_out"))

    get home_path
    expect(response).to redirect_to(new_user_session_path)
    get root_path
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("main h1").text).to eq("推し活の記録を、振り返る楽しみに。")
  end

  it "redirects unauthenticated visitors to sign-in" do
    get home_path
    expect(response).to redirect_to(new_user_session_path)
  end
end
