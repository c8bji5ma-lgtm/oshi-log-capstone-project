require "spec_helper"
require_relative "../../lib/public_app_host"

RSpec.describe PublicAppHost do
  describe ".resolve" do
    it "accepts one canonical IPv4 address" do
      expect(described_class.resolve("PUBLIC_APP_HOST" => "203.0.113.10")).to eq("203.0.113.10")
    end

    it "rejects a missing runtime host" do
      expect { described_class.resolve({}) }
        .to raise_error(PublicAppHost::ConfigurationError, "PUBLIC_APP_HOST is required in production")
    end

    it "rejects host names, ports, whitespace, and non-canonical IPv4 addresses" do
      [ "example.com", "203.0.113.10:443", " 203.0.113.10", "203.0.113.010", "::1" ].each do |value|
        expect { described_class.resolve("PUBLIC_APP_HOST" => value) }
          .to raise_error(PublicAppHost::ConfigurationError, "PUBLIC_APP_HOST must be one canonical IPv4 address")
      end
    end

    it "does not let the image-build flag bypass the required host" do
      expect { described_class.resolve("SECRET_KEY_BASE_DUMMY" => "1") }
        .to raise_error(PublicAppHost::ConfigurationError, "PUBLIC_APP_HOST is required in production")
    end
  end
end
