require "rails_helper"

RSpec.describe "Japanese error pages in the browser", type: :system do
  it "keeps all four error pages readable at narrow and desktop widths with a working return link" do
    directory = Rails.root.join("tmp/issue111")
    FileUtils.mkdir_p(directory)
    [ 375, 1280 ].each do |width|
      page.current_window.resize_to(width, 812)
      [ 400, 404, 422, 500 ].each do |status|
        visit "/#{status}.html"
        expect(page).to have_css("html[lang='ja']")
        expect(page).to have_css("main h1")
        expect(page).to have_text("エラー #{status}")
        expect(page).to have_link("トップページへ戻る", href: root_path)
        expect(page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")).to be(true)
        page.save_screenshot(directory.join("#{status}-#{width}.png"))
      end
    end
    click_link "トップページへ戻る"
    expect(page).to have_current_path(root_path)
    expect(page).to have_css("main h1", text: "OshiLog", exact_text: true)
  ensure
    page.current_window.resize_to(1280, 1024)
  end
end
