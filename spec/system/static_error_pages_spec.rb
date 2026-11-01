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
    expect(page).to have_css("main h1", text: "推し活の記録を、振り返る楽しみに。", exact_text: true)
  ensure
    page.current_window.resize_to(1280, 1024)
  end

  [ 375, 1280 ].each do |width|
    it "keeps the unsupported browser page accessible at #{width}px" do
      page.current_window.resize_to(width, 812)
      visit "/406-unsupported-browser.html"
      expect(page).to have_css("html[lang='ja']")
      expect(page).to have_css("main h1#error-title", text: "ブラウザーの更新が必要です", exact_text: true)
      expect(page).to have_css("article[aria-labelledby='error-title']")
      expect(page).to have_text("最新版のブラウザーでお試しください。")
      expect(page).to have_link("トップページへ戻る", href: root_path)

      find("body").send_keys(:tab)
      expect(page).to have_css("main a:focus-visible")
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const paragraph = document.querySelector('article > p:not(.status)');
          const article = document.querySelector('article');
          const link = document.querySelector('main a');
          const footer = document.querySelector('footer');
          const luminance = color => color.match(/[0-9.]+/g).slice(0, 3).map(Number)
            .map(value => value / 255).map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
            .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
          const contrast = (foreground, background) => {
            const a = luminance(foreground), b = luminance(background);
            return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
          };
          return {
            viewport: window.innerWidth, client: document.documentElement.clientWidth,
            scroll: document.documentElement.scrollWidth,
            fontSize: parseFloat(getComputedStyle(paragraph).fontSize),
            paragraphContrast: contrast(getComputedStyle(paragraph).color, getComputedStyle(article).backgroundColor),
            linkContrast: contrast(getComputedStyle(link).color, getComputedStyle(link).backgroundColor),
            footerContrast: contrast(getComputedStyle(footer).color, getComputedStyle(document.body).backgroundColor),
            linkHeight: link.getBoundingClientRect().height,
            outlineWidth: parseFloat(getComputedStyle(link).outlineWidth),
            outlineStyle: getComputedStyle(link).outlineStyle
          };
        })()
      JS
      puts "BROWSER_406_ACCESSIBILITY #{geometry.to_json}"
      expect(geometry["viewport"]).to eq(width)
      expect(geometry["scroll"]).to be <= geometry["client"]
      expect(geometry["fontSize"]).to be >= 16
      %w[paragraphContrast linkContrast footerContrast].each do |key|
        expect(geometry[key]).to be >= 4.5
      end
      expect(geometry["linkHeight"]).to be >= 44
      expect(geometry["outlineWidth"]).to be >= 3
      expect(geometry["outlineStyle"]).not_to eq("none")
      directory = Rails.root.join("tmp/issue31-406-japanese-final")
      FileUtils.mkdir_p(directory)
      page.save_screenshot(directory.join("406-#{width}-focused.png"))

      find("main a:focus-visible").send_keys(:enter)
      expect(page).to have_current_path(root_path)
      expect(page).to have_css("main h1", text: "推し活の記録を、振り返る楽しみに。", exact_text: true)
    ensure
      page.current_window.resize_to(1280, 1024)
    end
  end
end
