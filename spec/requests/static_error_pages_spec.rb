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
end
