require "spec_helper"
require_relative "local_test_database"

RSpec.describe LocalTestDatabase do
  let(:environment) { "test" }
  let(:database) { "my_app_test" }
  let(:host) { "localhost" }
  let(:host_address) { "127.0.0.1" }
  let(:server_address) { "127.0.0.1" }
  let(:client) { double("connected PG client", host: host, hostaddr: host_address) }
  let(:connection) do
    double("database connection", raw_connection: client,
      select_one: { "database" => database, "server_address" => server_address })
  end

  subject(:verification) { described_class.verify!(environment: environment, connection: connection) }

  [
    [ "Unix socket", "/var/run/postgresql", "", nil ],
    [ "Unix socket without a host address", "/var/run/postgresql", nil, nil ],
    [ "IPv4 loopback", "127.0.0.1", "127.0.0.1", "127.0.0.1" ],
    [ "IPv6 loopback", "::1", "::1", "::1" ],
    [ "localhost resolved to IPv6", "localhost", "::1", "::1" ],
    [ "loopback forwarding with a container-side server address", "localhost", "127.0.0.1", "172.18.0.2" ]
  ].each do |label, client_host, client_address, server|
    context "with #{label}" do
      let(:host) { client_host }
      let(:host_address) { client_address }
      let(:server_address) { server }

      it "accepts the established local test connection" do
        expect(verification).to include("database" => "my_app_test", "client_host" => client_host,
          "client_host_address" => client_address, "server_address" => server)
      end
    end
  end

  [
    [ "remote endpoint", "db.example.test", "203.0.113.10", "203.0.113.10" ],
    [ "private endpoint", "172.18.0.2", "172.18.0.2", "172.18.0.2" ],
    [ "localhost resolving to a private address", "localhost", "192.168.1.3", "172.18.0.2" ],
    [ "a hostname without its actual address", "localhost", nil, "127.0.0.1" ],
    [ "unknown client metadata", nil, nil, "127.0.0.1" ],
    [ "SQL loopback without client loopback", "db.example.test", "203.0.113.10", "127.0.0.1" ],
    [ "relative socket path", "tmp/postgresql", "", nil ],
    [ "socket with TCP metadata", "/var/run/postgresql", "127.0.0.1", nil ],
    [ "socket with a server address", "/var/run/postgresql", "", "127.0.0.1" ],
    [ "CIDR instead of a host", "127.0.0.0/8", "127.0.0.1", "127.0.0.1" ],
    [ "invalid actual address", "localhost", "not-an-address", "127.0.0.1" ]
  ].each do |label, client_host, client_address, server|
    context "with #{label}" do
      let(:host) { client_host }
      let(:host_address) { client_address }
      let(:server_address) { server }

      it "rejects the connection" do
        expect { verification }.to raise_error(RuntimeError, "Seed specs require the local test database")
      end
    end
  end

  %w[development production].each do |value|
    context "in #{value}" do
      let(:environment) { value }

      it "rejects the environment before querying the database" do
        expect(connection).not_to receive(:select_one)
        expect { verification }.to raise_error(RuntimeError, "Seed specs require the test environment")
      end
    end
  end

  %w[my_app_development my_app_production another_test].each do |value|
    context "with database #{value}" do
      let(:database) { value }

      it "rejects the database despite a local connection" do
        expect { verification }.to raise_error(RuntimeError, "Seed specs require the local test database")
      end
    end
  end
end
