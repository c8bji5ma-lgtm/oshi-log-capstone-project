require "rails_helper"

RSpec.describe Subscription, type: :model do
  include ActiveSupport::Testing::TimeHelpers
  describe "active dates" do
    let(:date) { Date.new(2026, 10, 6) }

    [
      [ nil, nil, true ], [ 0, nil, true ], [ -1, nil, true ], [ 1, nil, false ],
      [ nil, 0, true ], [ nil, 1, true ], [ nil, -1, false ],
      [ -1, 1, true ], [ 1, 2, false ], [ -2, -1, false ],
      [ 1, -1, false ], [ 0, -1, false ], [ 1, 0, false ]
    ].each do |start_offset, end_offset, active|
      it "matches scope and predicate for #{start_offset.inspect}/#{end_offset.inspect}" do
        record = create(:subscription, started_on: start_offset && date + start_offset, ended_on: end_offset && date + end_offset)
        expect(record.active_on?(date)).to eq(active)
        expect(described_class.active_on(date).exists?(record.id)).to eq(active)
      end
    end

    it "never activates an inverted interval" do
      record = create(:subscription, started_on: date + 1, ended_on: date - 1)
      [ date - 2, date - 1, date, date + 1, date + 2 ].each do |day|
        expect(record.active_on?(day)).to be(false)
        expect(described_class.active_on(day).exists?(record.id)).to be(false)
      end
    end

    it "defaults the predicate to today and chains owner and enum scopes" do
      travel_to(date) do
        user = create(:user)
        monthly = create(:subscription, user: user, started_on: date, ended_on: date)
        yearly = create(:subscription, :yearly, user: user)
        create(:subscription, user: user, started_on: date + 1)
        create(:subscription)
        expect(monthly.active_on?).to be(true)
        expect(user.subscriptions.active_on(Date.current).monthly).to contain_exactly(monthly)
        expect(user.subscriptions.active_on(Date.current).yearly).to contain_exactly(yearly)
      end
    end
  end

  it "belongs to its user and requires that user" do
    record = create(:subscription)
    expect(record.user.subscriptions).to contain_exactly(record)
    expect(build(:subscription, user: nil)).not_to be_valid
  end

  it "defines its associations without automatic deletion" do
    { user: :belongs_to, subscription_oshis: :has_many, oshis: :has_many }.each do |name, macro|
      association = described_class.reflect_on_association(name)
      expect(association.macro).to eq(macro)
      expect(association.options).not_to have_key(:dependent)
    end
    expect(described_class.reflect_on_association(:oshis).options[:through]).to eq(:subscription_oshis)
  end

  [ nil, "", " " ].each do |value|
    it "rejects name=#{value.inspect}" do
      expect(build(:subscription, name: value)).not_to be_valid
    end
  end

  it "accepts a 255-character name" do
    expect(build(:subscription, name: "あ" * 255)).to be_valid
  end

  it "rejects a 256-character name" do
    expect(build(:subscription, name: "あ" * 256)).not_to be_valid
  end

  [ 0, 1000 ].each do |value|
    it "persists amount=#{value}" do
      expect(create(:subscription, amount: value).reload.amount).to eq(value)
    end
  end

  [ nil, -1, 1.5, "1.5", "invalid", "" ].each do |value|
    it "rejects amount=#{value.inspect}" do
      record = build(:subscription, amount: value)
      expect(record).not_to be_valid
      expect(record.errors[:amount]).not_to be_empty
    end
  end

  [ "monthly", "yearly" ].each do |value|
    it "persists billing_cycle=#{value} as a string" do
      record = create(:subscription, billing_cycle: value)
      expect(record.reload.billing_cycle).to eq(value)
      expect(record.billing_cycle_before_type_cast).to eq(value)
    end
  end

  [ nil, "", "weekly" ].each do |value|
    it "rejects billing_cycle=#{value.inspect}" do
      expect(build(:subscription, billing_cycle: value)).not_to be_valid
    end
  end

  it "persists unset dates without filling them in" do
    record = create(:subscription)
    expect(record.reload.started_on).to be_nil
    expect(record.ended_on).to be_nil
  end

  [ :started_on, :ended_on ].each do |attribute|
    it "persists #{attribute} as a date" do
      date = Date.new(2025, 1, 15)
      expect(create(:subscription, attribute => date).reload.public_send(attribute)).to eq(date)
    end

    it "allows a future #{attribute}" do
      date = Date.current + 365
      expect(create(:subscription, attribute => date).reload.public_send(attribute)).to eq(date)
    end
  end

  it "allows ended_on before started_on" do
    record = create(:subscription, started_on: Date.new(2025, 2, 1), ended_on: Date.new(2025, 1, 1))
    expect(record.reload.ended_on).to be < record.started_on
  end

  [ 0, 1, 2 ].each do |count|
    it "persists #{count} oshis through subscription_oshis while retaining one amount" do
      oshis = create_list(:oshi, count)
      record = create(:subscription, oshis: oshis, amount: 1000)
      expect(record.reload.oshis).to match_array(oshis)
      expect(record.subscription_oshis.count).to eq(count)
      expect(record.amount).to eq(1000)
      oshis.each { |oshi| expect(oshi.subscriptions).to contain_exactly(record) }
    end
  end

  describe "database structure and constraints" do
    it "has the specified column types, limits, nullability, and defaults" do
      expected = {
        "id" => [ :integer, 8, false ],
        "user_id" => [ :integer, 8, false ],
        "name" => [ :string, 255, false ],
        "amount" => [ :integer, 4, false ],
        "billing_cycle" => [ :string, 20, false ],
        "started_on" => [ :date, nil, true ],
        "ended_on" => [ :date, nil, true ],
        "created_at" => [ :datetime, nil, false ],
        "updated_at" => [ :datetime, nil, false ],
        "lock_version" => [ :integer, 4, false ]
      }
      expect(described_class.column_names).to match_array(expected.keys)
      expected.each do |name, definition|
        column = described_class.columns_hash.fetch(name)
        expect([ column.type, column.limit, column.null ]).to eq(definition)
        if name == "lock_version"
          expect(column.default).to eq("0")
          expect(column.default_function).to be_nil
        elsif name != "id"
          expect(column.default).to be_nil
          expect(column.default_function).to be_nil
        end
      end
      [ "created_at", "updated_at" ].each do |name|
        expect(described_class.columns_hash.fetch(name).precision).to eq(6)
      end
    end

    [ :user_id, :name, :amount, :billing_cycle ].each do |attribute|
      it "rejects NULL #{attribute} without model validation" do
        record = build(:subscription, user: create(:user))
        record.public_send("#{attribute}=", nil)
        expect do
          described_class.transaction(requires_new: true) { record.save!(validate: false) }
        end.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "enforces the user foreign key" do
      record = build(:subscription, user: nil)
      record.user_id = User.maximum(:id).to_i + 1
      expect do
        described_class.transaction(requires_new: true) { record.save!(validate: false) }
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "has only the user_id nonunique index" do
      indexes = described_class.connection.indexes("subscriptions")
      expect(indexes.map { |index| [ index.columns, index.unique ] }).to contain_exactly([ [ "user_id" ], false ])
    end
  end
end
