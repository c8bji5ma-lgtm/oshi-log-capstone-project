require "ipaddr"

module PublicAppHost
  class ConfigurationError < StandardError; end

  def self.resolve(environment)
    value = environment["PUBLIC_APP_HOST"].to_s
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
