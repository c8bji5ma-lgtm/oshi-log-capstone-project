require "ipaddr"

module PublicAppHost
  class ConfigurationError < StandardError; end

  BUILD_FALLBACK = "127.0.0.1"

  def self.resolve(environment)
    value = environment["PUBLIC_APP_HOST"].to_s
    return BUILD_FALLBACK if value.empty? && environment["SECRET_KEY_BASE_DUMMY"].to_s == "1"

    raise ConfigurationError, "PUBLIC_APP_HOST is required in production" if value.empty?

    address = IPAddr.new(value)
    unless address.ipv4? && address.to_s == value
      raise ConfigurationError, "PUBLIC_APP_HOST must be one canonical IPv4 address"
    end

    value
  rescue IPAddr::InvalidAddressError
    raise ConfigurationError, "PUBLIC_APP_HOST must be one canonical IPv4 address"
  end
end
