require "rails_helper"

RSpec.describe "Chrome system test session isolation", type: :system do
  it "starts a fresh browser with no cookies or web storage after a Capybara reset" do
    visit new_user_session_path
    original_browser = page.driver.browser
    original_browser.manage.add_cookie(name: "oshilog_test_marker", value: "1", http_only: true)
    page.execute_script(<<~JS)
      localStorage.setItem('oshilog_test_marker', '1');
      sessionStorage.setItem('oshilog_test_marker', '1');
    JS
    script = <<~JS
      [localStorage.getItem('oshilog_test_marker'), sessionStorage.getItem('oshilog_test_marker')]
    JS
    expect(original_browser.manage.all_cookies.map { |cookie| cookie[:name] }).to include("oshilog_test_marker")
    expect(page.evaluate_script(script)).to eq([ "1", "1" ])
    extra_window = open_new_window
    within_window(extra_window) { visit new_user_session_path }
    original_browser.navigate.to("about:blank")

    Capybara.reset_sessions!
    visit new_user_session_path

    expect(page.driver.browser).not_to equal(original_browser)
    expect(page.windows.size).to eq(1)
    expect(page.driver.browser.manage.all_cookies.map { |cookie| cookie[:name] }).not_to include("oshilog_test_marker")
    expect(page.evaluate_script(script)).to eq([ nil, nil ])
  end
end
