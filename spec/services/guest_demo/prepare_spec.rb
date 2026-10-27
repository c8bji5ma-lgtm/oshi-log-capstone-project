require "rails_helper"
require_relative "../../support/local_test_database"

RSpec.describe GuestDemo::Prepare do
  before { LocalTestDatabase.verify!(environment: Rails.env, connection: User.connection) }

  around do |example|
    previous = ENV["OSHI_GUEST_SANDBOX"]
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    example.run
  ensure
    previous.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous
  end

  it "prepares demo-only accounts and browsable data in an empty test database" do
    expect(described_class.call).to eq(users: 5, oshis: 2, activities: 1)
    expect(GraduationGuestSandbox.ready?).to be_truthy
    expect(User.where(admin: true).count).to eq(1)
    expect(User.where.not(email: GraduationGuestSandbox::RESERVED_EMAILS)).not_to exist
    expect(Oshi.where(created_by_user_id: nil)).not_to exist
    expect(User.find_by!(email: GraduationGuestSandbox::ACCOUNTS.fetch("viewer")).activities.count).to eq(1)
  end

  it "refuses any existing user without changing that account" do
    user = create(:user)
    original = user.attributes
    expect { described_class.call }.to raise_error(/existing application dataset/)
    expect(user.reload.attributes).to eq(original)
    expect(User.count).to eq(1)
  end

  it "refuses existing records even if no users exist" do
    record = create(:oshi, :approved)
    expect { described_class.call }.to raise_error(/existing application dataset/)
    expect(record.reload).to be_present
    expect(User.count).to eq(0)
  end

  it "refuses repeat initialization instead of replacing demo data" do
    described_class.call
    original = User.order(:id).pluck(:id, :encrypted_password)
    expect { described_class.call }.to raise_error(/existing application dataset/)
    expect(User.order(:id).pluck(:id, :encrypted_password)).to eq(original)
  end

  it "does nothing while guest mode is disabled" do
    ENV.delete("OSHI_GUEST_SANDBOX")
    expect { described_class.call }.to raise_error(/must be enabled/)
    expect(User.count).to eq(0)
  end

  it "rolls back every new record if preparation fails partway through" do
    allow_any_instance_of(Activity).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Activity.new))

    expect { described_class.call }.to raise_error(ActiveRecord::RecordInvalid)
    expect([ User.count, Profile.count, Oshi.count, UserOshi.count, Activity.count, ActivityOshi.count ]).to eq([ 0, 0, 0, 0, 0, 0 ])
  end

  it "refuses a connection to any database outside the test allowlist" do
    allow(User.connection).to receive(:select_one)
      .with("SELECT current_database() AS database, current_user AS username")
      .and_return("database" => "my_app_production", "username" => "my_app")

    expect { described_class.call }.to raise_error(/local test database/)
    expect(User.count).to eq(0)
  end
end
