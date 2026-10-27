require "spec_helper"
require "active_record"
require "active_record/database_configurations"
require_relative "../../lib/graduation_guest_deployment"

RSpec.describe GraduationGuestDeployment do
  let(:environment) do
    { "OSHI_GUEST_SANDBOX" => "isolated", "OSHI_GUEST_SANDBOX_PRODUCTION_ACK" => "true",
      "RAILS_RELATIVE_URL_ROOT" => "/demo", "OSHI_GUEST_STORAGE_ROOT" => "/rails/demo-storage",
      "SECRET_KEY_BASE" => "test-only-" * 8 }
  end
  let(:configurations) do
    described_class::DATABASES.map { |name, database| { name: name, database: database, username: "oshilog_demo" } }
  end

  it "keeps the ordinary deployment unmounted and guest access disabled by default" do
    app = ->(_env) { [ 200, {}, [] ] }
    expect(described_class.enabled?(environment: "production", env: {})).to be(false)
    expect(described_class.rack_app(app, environment: "production", env: {})).to equal(app)
  end

  it "requires the production isolation acknowledgement" do
    environment.delete("OSHI_GUEST_SANDBOX_PRODUCTION_ACK")
    expect(described_class.enabled?(environment: "production", env: environment)).to be(false)
  end

  it "accepts the four dedicated databases and role" do
    expect(described_class.validate!(configurations: configurations, env: environment)).to be(true)
  end

  it "validates resolved connection URLs rather than the ordinary YAML defaults" do
    resolved = ActiveRecord::DatabaseConfigurations.new("production" => described_class::DATABASES.to_h do |name, database|
      [ name, { "adapter" => "postgresql", "database" => "my_app_production", "username" => "my_app",
        "url" => "postgresql://oshilog_demo@localhost/#{database}" } ]
    end).configs_for(env_name: "production").map do |configuration|
      configuration.configuration_hash.slice(:database, :username).merge(name: configuration.name)
    end

    expect(described_class.validate!(configurations: resolved, env: environment)).to be(true)
  end

  it "refuses an incomplete set of dedicated databases" do
    configurations.pop
    expect { described_class.validate!(configurations: configurations, env: environment) }.to raise_error(/four dedicated databases/)
  end

  %w[primary cache queue cable].each do |name|
    it "rejects an ordinary production #{name} database" do
      configurations.find { |c| c[:name] == name }[:database] = "my_app_production"
      expect { described_class.validate!(configurations: configurations, env: environment) }.to raise_error(/dedicated database/)
    end
  end

  it "rejects the ordinary production database role" do
    configurations.first[:username] = "my_app"
    expect { described_class.validate!(configurations: configurations, env: environment) }.to raise_error(/dedicated database/)
  end

  %w[RAILS_RELATIVE_URL_ROOT OSHI_GUEST_STORAGE_ROOT SECRET_KEY_BASE].each do |key|
    it "refuses a missing #{key}" do
      environment.delete(key)
      expect { described_class.validate!(configurations: configurations, env: environment) }.to raise_error(RuntimeError)
    end
  end

  it "isolates the secure demo cookie by both name and path" do
    expect(described_class.session_options(environment: "production")).to include(
      key: "_oshilog_demo_session", path: "/demo", secure: true, httponly: true, same_site: :lax)
  end
end
