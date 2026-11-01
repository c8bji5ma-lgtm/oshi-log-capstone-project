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
    previous_importmap = Rails.application.importmap
    ordinary = ActionDispatch::Integration::Session.new(Rails.application)
    ordinary.get "/"
    expect(ordinary.response).to have_http_status(:ok)
    @ordinary_imports = importmap_urls(ordinary.response)

    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    ActionController::Base.config.relative_url_root = "/demo"
    Rails.application.config.relative_url_root = "/demo"
    # Real deployments build separate maps at boot; resolved URLs are memoized.
    Rails.application.importmap = Importmap::Map.new.tap do |map|
      Rails.application.config.importmap.paths.each { |path| map.draw(path) }
    end
    example.run
  ensure
    previous_flag.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous_flag
    ActionController::Base.config.relative_url_root = previous_root
    Rails.application.config.relative_url_root = previous_application_root
    Rails.application.importmap = previous_importmap
    if ordinary && @ordinary_imports
      ordinary.get "/"
      expect(ordinary.response).to have_http_status(:ok)
      expect(importmap_urls(ordinary.response)).to eq(@ordinary_imports)
    end
  end

  def importmap_urls(response)
    document = Nokogiri::HTML(response.body)
    JSON.parse(document.at_css("script[type='importmap']").text).fetch("imports")
  end

  it "keeps entry forms, icons, stylesheets and importmap assets beneath /demo after an ordinary render" do
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

  it "resolves the same imports separately for the ordinary application and demo" do
    client.get "/demo/"
    expect(client.response).to have_http_status(:ok)
    expect(importmap_urls(client.response)).to eq(@ordinary_imports.transform_values { |path| "/demo#{path}" })
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

  [ true, false ].each do |ready|
    it "keeps the header guide and registration prohibition under /demo when guests are #{ready ? "ready" : "stopped"}" do
      create(:user) unless ready
      expect(GraduationGuestSandbox.ready?).to eq(ready)

      [ "/demo/", "/demo/users/sign_in" ].each do |path|
        client.get path
        expect(client.response).to have_http_status(:ok)
        document = Nokogiri::HTML(client.response.body)
        expect(document.css("nav a").map { |link| [ link.text, link["href"] ] }).to eq(
          [ [ "ログイン", "/demo/users/sign_in" ], [ "ゲストの案内", "/demo/" ] ]
        )
        expect(document.css("nav a[href*='#']")).to be_empty
        if path == "/demo/users/sign_in"
          expect(document.css("main .authentication-links a").map { |link| [ link.text, link["href"] ] }).to eq(
            [ [ "ゲストの案内", "/demo/" ] ]
          )
          expect(document.at_css("main a[href='/demo/users/sign_up']")).to be_nil
        end
      end

      client.get "/demo/"
      document = Nokogiri::HTML(client.response.body)
      expect(document.css("main form[action*='/guest/']").size).to eq(ready ? 2 : 0)
      expect(document.at_css("#public-top-guests").present?).to eq(ready)
      expect(document.at_css("main").text).to include("現在、ゲストの利用を停止しています。") unless ready

      client.get "/demo/users/sign_up"
      expect(client.response).to have_http_status(:forbidden)
      expect(client.response.body).to eq("デモ環境では新しいアカウントを登録できません。")
    end
  end
end
