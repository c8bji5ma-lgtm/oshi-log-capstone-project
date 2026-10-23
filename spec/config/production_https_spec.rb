require "spec_helper"
require "json"
require "open3"
require "rbconfig"

RSpec.describe "Production HTTPS configuration" do
  ROOT = File.expand_path("../..", __dir__)
  INSPECT_CONFIG = <<~'RUBY'
    require "json"
    config = Rails.application.config
    puts JSON.generate(
      assume_ssl: config.assume_ssl,
      force_ssl: config.force_ssl,
      hosts: config.hosts,
      mailer: config.action_mailer.default_url_options,
      health_host_excluded: config.host_authorization.fetch(:exclude).call(Struct.new(:path).new("/up")),
      root_host_excluded: config.host_authorization.fetch(:exclude).call(Struct.new(:path).new("/"))
    )
  RUBY

  it "uses the exact IPv4 host for Host authorization and HTTPS URLs" do
    stdout, stderr, status = run_production(
      "PUBLIC_APP_HOST" => "203.0.113.10",
      "SECRET_KEY_BASE_DUMMY" => "1"
    )

    expect(stderr).to eq("")
    expect(status).to be_success
    expect(JSON.parse(stdout)).to eq(
      "assume_ssl" => true,
      "force_ssl" => true,
      "hosts" => [ "203.0.113.10" ],
      "mailer" => { "host" => "203.0.113.10", "protocol" => "https" },
      "health_host_excluded" => true,
      "root_host_excluded" => false
    )
  end

  it "fails closed without a host even when the image-build flag is present" do
    _stdout, stderr, status = run_production("SECRET_KEY_BASE_DUMMY" => "1")

    expect(status).not_to be_success
    expect(stderr).to include("PUBLIC_APP_HOST is required in production")
  end

  def run_production(environment)
    clean_environment = {
      "RAILS_ENV" => "production",
      "PUBLIC_APP_HOST" => nil,
      "SECRET_KEY_BASE_DUMMY" => nil
    }.merge(environment)

    Open3.capture3(clean_environment, RbConfig.ruby, "bin/rails", "runner", INSPECT_CONFIG, chdir: ROOT)
  end
end
