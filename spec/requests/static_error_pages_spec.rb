require "rails_helper"

RSpec.describe "Standalone Japanese error pages", type: :request do
  {
    400 => [ ActionController::BadRequest, "リクエストを処理できません" ],
    404 => [ ActionController::RoutingError, "ページが見つかりません" ],
    422 => [ ActionController::InvalidAuthenticityToken, "操作を完了できません" ],
    500 => [ RuntimeError, "処理中に問題が発生しました" ]
  }.each do |status, (error_class, title)|
    it "preserves HTTP #{status} and serves the Japanese page without exception details" do
      # Exercise Rails' existing exception middleware without adding application routes
      # or changing the environment's exception handling configuration.
      app = ActionDispatch::ShowExceptions.new(
        ->(_env) { raise error_class, "private-error-detail /private/server/path" },
        ActionDispatch::PublicExceptions.new(Rails.public_path)
      )
      response = Rack::MockRequest.new(app).get("/", {
        "HTTP_ACCEPT" => "text/html",
        "action_dispatch.show_exceptions" => :all,
        "action_dispatch.show_detailed_exceptions" => false
      })
      document = Nokogiri::HTML(response.body)

      expect(response.status).to eq(status)
      expect(response.content_type).to start_with("text/html")
      expect(document.at_css("html")["lang"]).to eq("ja")
      expect(document.at_css("title").text).to include(status.to_s, title, "OshiLog")
      expect(document.at_css("main h1").text).to eq(title)
      expect(document.at_css("main a[href='/']").text).to eq("トップページへ戻る")
      expect(response.body).not_to include("private-error-detail", "/private/server/path", "application owner check the logs")
      expect(response.body).to eq(Rails.public_path.join("#{status}.html").read)
    end
  end

  context "browser compatibility" do
    let(:supported_agent) do
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
    end

    it "continues to serve the top page to a supported browser" do
      get root_path, headers: { "User-Agent" => supported_agent, "Accept" => "text/html" }

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css("main h1").text).to eq("OshiLog")
    end

    it "serves the Japanese update guidance with HTTP 406 to an unsupported browser" do
      unsupported_agent = supported_agent.sub("Chrome/151.0.0.0", "Chrome/100.0.0.0")
      get root_path, headers: { "User-Agent" => unsupported_agent, "Accept" => "text/html" }
      document = Nokogiri::HTML(response.body)

      expect(response).to have_http_status(:not_acceptable)
      expect(response.media_type).to eq("text/html")
      expect(document.at_css("html")["lang"]).to eq("ja")
      expect(document.at_css("title").text).to eq("406｜ブラウザーの更新が必要です｜OshiLog")
      expect(document.at_css("article")["aria-labelledby"]).to eq("error-title")
      expect(document.at_css("main h1#error-title").text).to eq("ブラウザーの更新が必要です")
      expect(document.at_css("article").text).to include("最新版のブラウザーでお試しください。")
      expect(document.at_css("main a[href='/']").text).to eq("トップページへ戻る")
      expect(response.body).not_to include("Your browser is not supported", Rails.root.to_s)
      expect(response.body).to eq(Rails.public_path.join("406-unsupported-browser.html").read)
    end
  end
end
