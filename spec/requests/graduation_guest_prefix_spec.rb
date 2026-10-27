require "rails_helper"

RSpec.describe "デモのサブパス", type: :request do
  let(:client) { ActionDispatch::Integration::Session.new(Rack::URLMap.new("/demo" => Rails.application)) }

  before do
    GraduationGuestSandbox::RESERVED_EMAILS.each do |email|
      create(:user, email: email, admin: email == GraduationGuestSandbox::ACCOUNTS.fetch("admin"))
    end
  end

  around do |example|
    previous_flag = ENV["OSHI_GUEST_SANDBOX"]
    previous_root = ActionController::Base.config.relative_url_root
    previous_application_root = Rails.application.config.relative_url_root
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    ActionController::Base.config.relative_url_root = "/demo"
    Rails.application.config.relative_url_root = "/demo"
    example.run
  ensure
    previous_flag.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous_flag
    ActionController::Base.config.relative_url_root = previous_root
    Rails.application.config.relative_url_root = previous_application_root
  end

  it "keeps entry forms, icons, stylesheets and importmap assets beneath /demo" do
    client.get "/demo/"
    expect(client.response).to have_http_status(:ok)
    document = Nokogiri::HTML(client.response.body)
    expect(document.css("form").map { |form| form["action"] }).to include("/demo/guest/viewer", "/demo/guest/admin")
    paths = document.css("link[href]").map { |link| link["href"] }
    imports = JSON.parse(document.at_css("script[type='importmap']").text).fetch("imports").values
    (paths + imports).each do |path|
      expect(path).to start_with("/demo/")
      client.get path
      expect(client.response).to have_http_status(:ok)
    end
  end

  it "keeps viewer redirects and logout inside the mount and rejects administrator access" do
    client.post "/demo/guest/viewer"
    expect(client.response).to have_http_status(:see_other)
    expect(client.response.location).to eq("http://www.example.com/demo/")
    client.get "/demo/my_page"
    expect(client.response).to have_http_status(:ok)
    client.get "/demo/admin/oshis"
    expect(client.response).to have_http_status(:forbidden)
    client.delete "/demo/users/sign_out"
    expect(client.response.location).to end_with("/demo/users/sign_in")
    client.get "/demo/my_page"
    expect(client.response.location).to end_with("/demo/users/sign_in")
  end

  it "allows administrator browsing but refuses mutations under the mount" do
    client.post "/demo/guest/admin"
    client.get "/demo/admin/oshis"
    expect(client.response).to have_http_status(:ok)
    record = create(:oshi, :pending, created_by_user: User.find_by!(email: GraduationGuestSandbox::ACCOUNTS.fetch("viewer")))
    client.patch "/demo/admin/oshis/#{record.id}/approve"
    expect(client.response).to have_http_status(:forbidden)
    expect(record.reload).to be_pending
    client.delete "/demo/users/sign_out"
    expect(client.response.location).to end_with("/demo/users/sign_in")
  end
end
