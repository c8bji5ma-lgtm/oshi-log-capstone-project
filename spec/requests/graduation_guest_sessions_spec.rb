require "rails_helper"

RSpec.describe "卒業課題のゲストログイン", type: :request do
  let!(:viewer) { create(:user, email: "demo@example.com") }
  let!(:administrator) { create(:user, :admin, email: "admin@example.com") }

  before do
    %w[multi light empty].each do |name|
      create(:user, email: "#{name}@example.com")
    end
  end

  around do |example|
    previous = ENV["OSHI_GUEST_SANDBOX"]
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    example.run
  ensure
    previous.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous
  end

  it "shows separate guest login buttons for the demo-only database" do
    get root_path
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("form[action='#{guest_session_path(role: "viewer")}']")).to be_present
    expect(document.at_css("form[action='#{guest_session_path(role: "admin")}']")).to be_present
    expect(document.at_css("main a[href='#public-top-guests']").text).to eq("ゲストで画面を見る")
    expect(document.at_css("main a[href='#{new_user_registration_path}']")).to be_nil
    expect(document.at_css("main").text).to include("新しいアカウントを登録できません", "通常版で記録を始める手順")
  end

  it "allows the viewer guest to browse but not access administrator actions" do
    post guest_session_path(role: "viewer")
    expect(response).to redirect_to(root_path)
    get my_page_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("マイページ")

    get admin_oshis_path
    expect(response).to have_http_status(:forbidden)
    post activities_path, params: { activity: { title: "ゲストの書き込み" } }
    expect(response).to have_http_status(:forbidden)
  end

  it "allows administrator guest access without allowing approval or deletion" do
    record = create(:oshi, :pending, created_by_user: viewer)
    post guest_session_path(role: "admin")
    expect(response).to redirect_to(root_path)

    get admin_oshis_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("推し承認管理")

    patch approve_admin_oshi_path(record)
    expect(response).to have_http_status(:forbidden)
    expect(record.reload).to be_pending

    delete admin_oshi_common_image_path(99)
    expect(response).to have_http_status(:forbidden)
  end

  it "signs out and refuses normal password sign-in for the published demo accounts" do
    post guest_session_path(role: "admin")
    delete destroy_user_session_path
    expect(response).to redirect_to(new_user_session_path)
    get admin_oshis_path
    expect(response).to redirect_to(new_user_session_path)

    post user_session_path,
      params: { user: { email: administrator.email, password: "password123" } }
    expect(response).not_to redirect_to(root_path)
    get admin_oshis_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "disables guest access and registration as soon as real users are present" do
    post guest_session_path(role: "admin")
    create(:user, email: "actual-customer@example.org")

    get admin_oshis_path
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response.body).to include("ゲスト利用を終了しました。")
    post guest_session_path(role: "viewer")
    expect(response).to have_http_status(:not_found)
    get new_user_registration_path
    expect(response).to have_http_status(:forbidden)
    get root_path
    document = Nokogiri::HTML(response.body)
    expect(document.css("main form[action*='/guest/']")).to be_empty
    expect(document.at_css("main a[href='#{new_user_registration_path}']")).to be_nil
    expect(document.at_css("main").text).to include("現在、ゲストの利用を停止しています。")
  end

  it "does not expose either guest login when the sandbox flag is absent" do
    ENV.delete("OSHI_GUEST_SANDBOX")
    get root_path
    expect(response.body).not_to include("管理者としてゲストログイン")
    post guest_session_path(role: "admin")
    expect(response).to have_http_status(:not_found)
  end

  context "pre-existing sessions when sandbox mode starts" do
    def sign_in_before_sandbox_activation(account)
      ENV.delete("OSHI_GUEST_SANDBOX")
      post user_session_path,
        params: { user: { email: account.email, password: "password123" } }
      expect(response).to redirect_to(root_path)
      get my_page_path
      expect(response).to have_http_status(:ok)
      expect(request.session[:graduation_guest_role]).to be_nil
      ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    end

    %w[demo multi light empty admin].each do |name|
      it "expires the #{name} account session before a profile update" do
        account = User.find_by!(email: "#{name}@example.com")
        profile = create(:profile, user: account, display_name: "変更前")
        sign_in_before_sandbox_activation(account)

        expect {
          patch profile_path, params: { profile: { display_name: "変更後" } }
        }.not_to change { profile.reload.display_name }
        expect(response).to redirect_to(root_path)

        get my_page_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    %w[demo admin].each do |name|
      it "expires the #{name} account session on a read request" do
        sign_in_before_sandbox_activation(User.find_by!(email: "#{name}@example.com"))

        get my_page_path
        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("ゲスト利用を終了しました。")

        get my_page_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    it "expires the administrator session before approving a record" do
      record = create(:oshi, :pending, created_by_user: viewer)
      sign_in_before_sandbox_activation(administrator)

      expect {
        patch approve_admin_oshi_path(record)
      }.not_to change { record.reload.status }
      expect(response).to redirect_to(root_path)

      get admin_oshis_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  %w[demo admin].each do |name|
    it "allows normal #{name} account sign-in and updates while sandbox mode is disabled" do
      ENV.delete("OSHI_GUEST_SANDBOX")
      account = User.find_by!(email: "#{name}@example.com")
      profile = create(:profile, user: account, display_name: "変更前")
      post user_session_path,
        params: { user: { email: account.email, password: "password123" } }
      expect(response).to redirect_to(root_path)

      patch profile_path, params: { profile: { display_name: "変更後" } }
      expect(response).to redirect_to(my_page_path)
      expect(profile.reload.display_name).to eq("変更後")
    end
  end

  it "expires a marked guest session when sandbox mode is disabled" do
    post guest_session_path(role: "admin")
    expect(response).to redirect_to(root_path)
    ENV.delete("OSHI_GUEST_SANDBOX")

    get admin_oshis_path
    expect(response).to redirect_to(root_path)
    get admin_oshis_path
    expect(response).to redirect_to(new_user_session_path)
  end
end
