require "ipaddr"

module LocalTestDatabase
  def self.verify!(environment:, connection:)
    raise "Seed specs require the test environment" unless environment.to_s == "test"

    details = connection.select_one("SELECT current_database() AS database, inet_server_addr()::text AS server_address")
    client = connection.raw_connection
    details = details.merge("client_host" => client.host, "client_host_address" => client.hostaddr)
    raise "Seed specs require the local test database" unless details["database"] == "my_app_test" && local_endpoint?(details)

    details
  end

  def self.local_endpoint?(details)
    host = details["client_host"]
    address = details["client_host_address"]
    if host.is_a?(String) && host.start_with?("/")
      return address.to_s.empty? && details.key?("server_address") && details["server_address"].nil?
    end

    # Docker port forwarding can give inet_server_addr() a container address.
    # TCP locality is proved by the established client's host and hostaddr.
    (host == "localhost" || loopback?(host)) && loopback?(address)
  end

  def self.loopback?(address)
    return false unless address.is_a?(String) && !address.include?("/")

    IPAddr.new(address).loopback?
  rescue IPAddr::InvalidAddressError
    false
  end

  private_class_method :local_endpoint?, :loopback?
end
