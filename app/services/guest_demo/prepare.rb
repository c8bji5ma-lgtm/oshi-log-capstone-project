require "ipaddr"

module GuestDemo
  class Prepare
    def self.call
      new.call
    end

    def call
      raise "Guest sandbox must be enabled" unless GraduationGuestSandbox.enabled?

      verify_database!
      User.transaction(requires_new: true) do
        # Serialize preparation before checking that no application data exists.
        User.connection.execute("LOCK TABLE users IN EXCLUSIVE MODE")
        verify_empty!
        Emotion.seed_defaults!
        users = GraduationGuestSandbox::RESERVED_EMAILS.to_h do |email|
          administrator = email == GraduationGuestSandbox::ACCOUNTS.fetch("admin")
          user = User.create!(email: email, admin: administrator, password: SecureRandom.hex(32))
          user.create_profile!(display_name: administrator ? "管理者ゲスト" : "デモユーザー")
          [ email, user ]
        end
        viewer = users.fetch(GraduationGuestSandbox::ACCOUNTS.fetch("viewer"))
        viewer.profile.update!(display_name: "一般ゲスト")
        oshi = Oshi.create!(name: "デモの推し", oshi_type: "アーティスト", status: :approved, created_by_user: viewer)
        Oshi.create!(name: "承認待ちのデモ", oshi_type: "アーティスト", status: :pending, created_by_user: viewer)
        viewer.user_oshis.create!(oshi: oshi)
        activity = viewer.activities.new(title: "デモのライブ記録", occurred_on: Date.new(2026, 10, 1), activity_type: Activity::ACTIVITY_TYPES.first)
        activity.activity_oshis.build(oshi: oshi)
        activity.save!
      end
      { users: User.count, oshis: Oshi.count, activities: Activity.count }
    end

    private

      def verify_database!
        connection = User.connection
        details = connection.select_one("SELECT current_database() AS database, current_user AS username")
        if Rails.env.test?
          client = connection.raw_connection
          local = if client.host.start_with?("/")
            client.hostaddr.to_s.empty?
          else
            (client.host == "localhost" || loopback?(client.host)) && loopback?(client.hostaddr)
          end
          raise "Guest preparation requires the local test database" unless details["database"] == "my_app_test" && local
        elsif Rails.env.production?
          configurations = ActiveRecord::Base.configurations.configs_for(env_name: "production").map do |configuration|
            configuration.configuration_hash.slice(:database, :username).merge(name: configuration.name)
          end
          GraduationGuestDeployment.validate!(configurations: configurations)
          unless details["database"] == GraduationGuestDeployment::DATABASES.fetch("primary") && details["username"] == GraduationGuestDeployment::DATABASE_ROLE
            raise "Guest preparation requires the dedicated database connection"
          end
        else
          raise "Guest preparation is not available in this environment"
        end
      end

      def loopback?(address)
        IPAddr.new(address.to_s).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end

      def verify_empty!
        connection = User.connection
        tables = connection.tables - %w[schema_migrations ar_internal_metadata emotions]
        occupied = tables.any? do |table|
          connection.select_value("SELECT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)} LIMIT 1)")
        end
        if occupied || Emotion.where.not(name: Emotion::DEFAULT_NAMES).exists?
          raise "Guest preparation refuses an existing application dataset"
        end
      end
  end
end
