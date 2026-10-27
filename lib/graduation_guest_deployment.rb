require "rack/urlmap"

module GraduationGuestDeployment
  MOUNT_PATH = "/demo".freeze
  STORAGE_ROOT = "/rails/demo-storage".freeze
  DATABASE_ROLE = "oshilog_demo".freeze
  DATABASES = {
    "primary" => "oshilog_demo", "cache" => "oshilog_demo_cache",
    "queue" => "oshilog_demo_queue", "cable" => "oshilog_demo_cable"
  }.freeze

  def self.enabled?(environment:, env: ENV)
    env["OSHI_GUEST_SANDBOX"] == "isolated" &&
      (environment.to_s == "test" || env["OSHI_GUEST_SANDBOX_PRODUCTION_ACK"] == "true")
  end

  def self.session_options(environment:)
    { key: "_oshilog_demo_session", path: MOUNT_PATH, httponly: true,
      same_site: :lax, secure: environment.to_s == "production" }
  end

  def self.rack_app(app, environment:, env: ENV)
    return app unless enabled?(environment: environment, env: env)
    raise "Guest deployment requires /demo" unless env["RAILS_RELATIVE_URL_ROOT"] == MOUNT_PATH

    Rack::URLMap.new(MOUNT_PATH => app)
  end

  def self.validate!(configurations:, env: ENV)
    raise "Guest deployment requires /demo" unless env["RAILS_RELATIVE_URL_ROOT"] == MOUNT_PATH
    raise "Guest deployment requires its own storage mount" unless env["OSHI_GUEST_STORAGE_ROOT"] == STORAGE_ROOT
    raise "Guest deployment requires its own secret key" unless env["SECRET_KEY_BASE"].to_s.length >= 64
    raise "Guest deployment requires four dedicated databases" unless configurations.map { |c| c[:name] }.sort == DATABASES.keys.sort

    configurations.each do |configuration|
      unless configuration[:database] == DATABASES.fetch(configuration[:name]) && configuration[:username] == DATABASE_ROLE
        raise "Guest deployment requires dedicated database names and role"
      end
    end
    true
  end
end
