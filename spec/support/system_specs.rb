# Capybara 3.40 passes an invalid wildcard origin to Chrome's storage API.
# Discard the disposable Selenium profile instead of weakening test isolation.
require "capybara/selenium/driver"

module FreshChromeProfileOnReset
  def reset!
    quit
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(FreshChromeProfileOnReset)

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driver_options = {}
    if ENV["GITHUB_ACTIONS"] == "true"
      require "selenium/webdriver"
      directory = Rails.root.join("tmp/chrome-diagnostics")
      FileUtils.mkdir_p(directory)
      driver_options[:service] = Selenium::WebDriver::Service.chrome(
        log: directory.join("chromedriver-#{SecureRandom.hex(6)}.log").to_s,
        args: [ "--log-level=INFO" ]
      )
    end

    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 1024 ], options: driver_options do |options|
      options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?
      # Ubuntu's AppArmor allowlist does not cover setup-chrome's Chrome for Testing path.
      options.add_argument("--no-sandbox") if ENV["GITHUB_ACTIONS"] == "true"
      # Chrome's warning about test credentials can block browser clicks.
      options.add_preference("profile.password_manager_leak_detection", false)
    end
  end
end
