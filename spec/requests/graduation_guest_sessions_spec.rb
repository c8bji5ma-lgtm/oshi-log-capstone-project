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
  end

  it "does not expose either guest login when the sandbox flag is absent" do
    ENV.delete("OSHI_GUEST_SANDBOX")
    get root_path
    expect(response.body).not_to include("管理者としてゲストログイン")
    post guest_session_path(role: "admin")
    expect(response).to have_http_status(:not_found)
  end
end
