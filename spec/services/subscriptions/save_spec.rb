require "rails_helper"
require "timeout"

RSpec.describe Subscriptions::Save do
  def save_subscription(record, attributes: {}, oshi_ids: nil, expected_lock_version: nil)
    described_class.call(subscription: record, attributes: attributes, oshi_ids: oshi_ids,
      expected_lock_version: expected_lock_version)
  end

  [ 0, 1, 2 ].each do |count|
    it "creates a contract with #{count} oshis and one amount" do
      record = build(:subscription)
      ids = create_list(:oshi, count).map(&:id)
      save_subscription(record, oshi_ids: ids)
      expect(record.reload.oshi_ids).to match_array(ids)
      expect(record.amount).to eq(1000)
    end
  end

  it "leaves no parent or children for an invalid parent" do
    record = build(:subscription, name: nil)
    ids = [ create(:oshi).id ]
    counts = [ Subscription.count, SubscriptionOshi.count ]
    expect { save_subscription(record, oshi_ids: ids) }.to raise_error(ActiveRecord::RecordInvalid)
    expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
  end

  it "rolls back a saved parent and earlier joins when a later join fails" do
    record = build(:subscription)
    oshi = create(:oshi)
    counts = [ Subscription.count, SubscriptionOshi.count ]
    expect do
      save_subscription(record, oshi_ids: [ oshi.id, Oshi.maximum(:id) + 1 ])
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect([ Subscription.count, SubscriptionOshi.count ]).to eq(counts)
  end

  it "retains links for a scalar-only update" do
    record = create(:subscription, oshis: [ create(:oshi) ])
    join = record.subscription_oshis.first
    save_subscription(record, attributes: { name: "更新", amount: 0 })
    expect(record.reload.name).to eq("更新")
    expect(record.amount).to eq(0)
    expect(record.subscription_oshis.pluck(:id)).to eq([ join.id ])
  end

  it "replaces A,B with B,C while retaining B and normalizing duplicates" do
    a, b, c = create_list(:oshi, 3)
    record = create(:subscription, oshis: [ a, b ])
    retained = record.subscription_oshis.find_by!(oshi: b).id
    save_subscription(record, oshi_ids: [ b.id, c.id.to_s, c.id ])
    expect(record.reload.oshi_ids).to match_array([ b.id, c.id ])
    expect(record.subscription_oshis.find_by!(oshi: b).id).to eq(retained)
  end

  it "clears all links and subsequently adds multiple links" do
    record = create(:subscription, oshis: [ create(:oshi) ])
    save_subscription(record, oshi_ids: [])
    expect(record.reload.oshis).to be_empty
    ids = create_list(:oshi, 2).map(&:id)
    save_subscription(record, oshi_ids: ids)
    expect(record.reload.oshi_ids).to match_array(ids)
  end

  it "preserves every scalar and join when parent validation fails" do
    record = create(:subscription, oshis: [ create(:oshi) ])
    original = record.attributes
    joins = record.subscription_oshis.pluck(:id)
    expect do
      save_subscription(record, attributes: { name: "", amount: 0, billing_cycle: "yearly", started_on: Date.current, ended_on: Date.current }, oshi_ids: [ create(:oshi).id ])
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(record.reload.attributes).to eq(original)
    expect(record.subscription_oshis.pluck(:id)).to eq(joins)
  end

  it "rolls back scalars and additions when a later join fails" do
    record = create(:subscription, oshis: [ create(:oshi) ])
    replacement = create(:oshi)
    original = record.attributes
    joins = record.subscription_oshis.pluck(:id)
    expect do
      save_subscription(record, attributes: { name: "失敗", amount: 0, billing_cycle: "yearly", started_on: Date.current, ended_on: Date.current }, oshi_ids: [ replacement.id, Oshi.maximum(:id) + 1 ])
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(record.reload.attributes).to eq(original)
    expect(record.subscription_oshis.pluck(:id)).to eq(joins)
  end

  it "rolls back additions and scalar changes if removal fails" do
    record = create(:subscription, oshis: [ create(:oshi) ])
    original = record.attributes
    joins = record.subscription_oshis.pluck(:id)
    allow(record).to receive(:save!).and_wrap_original do |original_save|
      original_save.call
      allow(record.subscription_oshis).to receive(:where).and_raise(ActiveRecord::RecordNotDestroyed)
    end
    expect do
      save_subscription(record, attributes: { name: "失敗" }, oshi_ids: [ create(:oshi).id ])
    end.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(record.reload.attributes).to eq(original)
    expect(record.subscription_oshis.pluck(:id)).to eq(joins)
  end

  it "refreshes stale links and locks the parent before updating" do
    record = create(:subscription)
    record.subscription_oshis.load
    oshi = create(:oshi)
    create(:subscription_oshi, subscription: Subscription.find(record.id), oshi: oshi)
    statements = []
    listener = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      save_subscription(record, attributes: { name: "ロック" }, oshi_ids: [ oshi.id ])
    ensure
      ActiveSupport::Notifications.unsubscribe(listener)
    end
    expect(record.reload.oshi_ids).to eq([ oshi.id ])
    lock_index = statements.index { |sql| sql.include?('FROM "subscriptions"') && sql.include?("FOR UPDATE") }
    update_index = statements.index { |sql| sql.start_with?('UPDATE "subscriptions"') }
    expect(lock_index).not_to be_nil
    expect(update_index).not_to be_nil
    expect(lock_index).to be < update_index
  end

  it "rejects a stale expected version before changing attributes or links" do
    record = create(:subscription, oshis: [ create(:oshi) ])
    stale_version = record.lock_version
    replacement = create(:oshi)
    described_class.call(subscription: Subscription.find(record.id), attributes: { name: "先行更新" },
      oshi_ids: [ replacement.id ], expected_lock_version: stale_version)
    latest = record.reload.attributes
    latest_ids = record.oshi_ids

    expect do
      described_class.call(subscription: record, attributes: { name: "古い更新" }, oshi_ids: [ create(:oshi).id ],
        expected_lock_version: stale_version)
    end.to raise_error(ActiveRecord::StaleObjectError)
    expect(record.reload.attributes).to eq(latest)
    expect(record.oshi_ids).to eq(latest_ids)
  end

  it "advances the parent version for a links-only update" do
    record = create(:subscription)
    version = record.lock_version
    described_class.call(subscription: record, oshi_ids: [ create(:oshi).id ], expected_lock_version: version)
    expect(record.reload.lock_version).to be > version
  end

  describe "concurrent updates on separate connections" do
    self.use_transactional_tests = false

    it "commits one update and rejects the other snapshot as stale" do
      record = create(:subscription)
      subscription_id = record.id
      user_id = record.user_id
      ready = Queue.new
      release = Queue.new
      results = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            candidate = Subscription.find(record.id)
            expected_version = candidate.lock_version
            ready << true
            release.pop
            described_class.call(subscription: candidate, attributes: { name: "同時更新#{index}" },
              expected_lock_version: expected_version)
            results << [ :saved, index ]
          rescue StandardError => error
            results << [ :failed, error ]
          end
        end
      end
      Timeout.timeout(10) { 2.times { ready.pop } }
      2.times { release << true }
      threads.each { |thread| expect(thread.join(10)).to eq(thread) }
      outcomes = 2.times.map { results.pop }
      saved = outcomes.select { |status, _| status == :saved }
      failed = outcomes.select { |status, _| status == :failed }
      expect(saved.size).to eq(1)
      expect(failed.map(&:last)).to all(be_a(ActiveRecord::StaleObjectError))
      expect(record.reload.name).to eq("同時更新#{saved.sole.last}")
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      SubscriptionOshi.where(subscription_id: subscription_id).delete_all if subscription_id
      Subscription.where(id: subscription_id).delete_all if subscription_id
      User.where(id: user_id).delete_all if user_id
    end
  end
end
