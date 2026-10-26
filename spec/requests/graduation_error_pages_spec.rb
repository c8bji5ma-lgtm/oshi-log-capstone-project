require "rails_helper"

RSpec.describe "卒業課題の独自エラーページと共通フッター", type: :request do
  { 400 => "リクエストを処理できません", 404 => "ページが見つかりません",
    422 => "操作を完了できません", 500 => "処理中に問題が発生しました" }.each do |status, title|
    it "provides a standalone Japanese #{status} page without private details" do
      html = Rails.public_path.join("#{status}.html").read
      doc = Nokogiri::HTML(html)
      expect(doc.at_css("html")["lang"]).to eq("ja")
      expect(doc.at_css("title").text).to include(title, "OshiLog")
      expect(doc.at_css("h1").text).to eq(title)
      expect(doc.at_css("main a")["href"]).to eq("/")
      expect(doc.at_css("main a").text).to eq("トップページへ戻る")
      expect(html).not_to include("Internal Server Error", "application owner check the logs")
    end
  end

  it "renders the footer below the page content for a visitor" do
    get root_path
    document = Nokogiri::HTML(response.body)
    expect(response).to have_http_status(:ok)
    expect(document.at_css("body > header")).to be_present
    expect(document.at_css("body > main")).to be_present
    footer = document.at_css("body > footer.site-footer")
    expect(footer).to be_present
    expect(footer.text).to include("OshiLog")
    expect(footer.at_css("a")["href"]).to eq(root_path)
  end
end
