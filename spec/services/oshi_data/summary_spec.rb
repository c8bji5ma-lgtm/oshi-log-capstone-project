require "rails_helper"

RSpec.describe OshiData::Summary do
  let(:user) { create(:user) }
  let(:date) { Date.new(2026, 10, 6) }
  let(:oshi) { create(:oshi, :approved, name: "推しA") }
  let(:second_oshi) { create(:oshi, :rejected, name: "推しB") }

  before do
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second_oshi, ended_period: "2025")
  end

  def activity(oshis: [ oshi ], owner: user, **attributes)
    record = build(:activity, :without_oshis, user: owner, **attributes)
    oshis.each { |selected| UserOshi.find_or_create_by!(user: owner, oshi: selected) }
    Activities::Save.call(activity: record, oshi_ids: oshis.map(&:id))
  end

  def summary(**options)
    described_class.new(user: user, date: date, **options)
  end

  it "returns empty values, calendar months, and no invented insight" do
    result = summary
    expect(result.activity_count).to eq(0)
    expect(result.activity_amount).to eq(0)
    expect(result.amount_recorded?).to be(false)
    expect(result.monthly_average).to be_nil
    expect(result.monthly_activities).to eq((1..10).map { |month| { month: month, count: 0 } })
    expect(result.categories).to be_empty
    expect(result.highlight).to be_nil
    expect(result.per_oshi.map { |row| row[:count] }).to eq([ 0, 0 ])
    expect([ result.monthly_fixed_cost, result.yearly_fixed_cost ]).to eq([ 0, 0 ])
  end

  it "counts each parent once and sums equal amounts without deduplicating money" do
    activity(amount: 1000)
    activity(amount: 1000, oshis: [ oshi, second_oshi ])
    activity(amount: nil)
    activity(amount: 0)
    result = summary
    expect(result.activity_count).to eq(4)
    expect(result.activity_amount).to eq(2000)
    expect(result.common_amount).to eq(1000)
    expect(result.amount_recorded?).to be(true)
    expect(result.monthly_average).to eq(200)
    expect(result.per_oshi.map { |row| [ row[:oshi], row[:count] ] }).to eq([ [ oshi, 4 ], [ second_oshi, 1 ] ])
  end

  it "distinguishes all nil from an explicitly recorded zero" do
    record = activity(amount: nil)
    expect(summary.amount_recorded?).to be(false)
    expect(summary.monthly_average).to be_nil
    record.update!(amount: 0)
    expect(summary.amount_recorded?).to be(true)
    expect(summary.monthly_average).to eq(0)
  end

  it "includes common activities in counts but only sole-oshi amounts in selected expenditure" do
    activity(amount: 1000)
    activity(amount: 2000, oshis: [ oshi, second_oshi ])
    result = summary(oshi: oshi)
    expect(result.activity_count).to eq(2)
    expect(result.activity_amount).to eq(1000)
    expect(result.common_amount).to eq(2000)
    expect(result.per_oshi).to eq([ { oshi: oshi, count: 2 } ])
    common_only = summary(oshi: second_oshi)
    expect(common_only.activity_amount).to eq(0)
    expect(common_only.amount_recorded?).to be(true)
    expect(common_only.monthly_average).to eq(0)
    expect(summary.activity_amount).to eq(3000)
  end

  it "does not treat unrecorded common expenses as recorded zero" do
    activity(amount: nil, oshis: [ oshi, second_oshi ])
    expect(summary(oshi: second_oshi).amount_recorded?).to be(false)
  end

  it "uses occurred_on, excludes future dates, and groups current and past calendar years" do
    activity(occurred_on: Date.new(2026, 1, 1), created_at: Time.utc(2025, 4, 1))
    activity(occurred_on: date)
    activity(occurred_on: date + 1, amount: 5000)
    activity(occurred_on: Date.new(2025, 12, 31), amount: 1000)
    result = summary
    expect(result.activity_count).to eq(2)
    expect(result.monthly_activities.first).to eq(month: 1, count: 1)
    expect(result.monthly_activities.last).to eq(month: 10, count: 1)
    expect(result.monthly_activities[1]).to eq(month: 2, count: 0)
    past = summary(year: 2025)
    expect(past.activity_count).to eq(1)
    expect(past.monthly_activities.size).to eq(12)
    expect(past.monthly_activities.last).to eq(month: 12, count: 1)
    expect(past.monthly_average).to eq(83)
  end

  it "rounds averages using every elapsed calendar month, including inactive months" do
    activity(amount: 128_500)
    expect(summary(date: Date.new(2026, 9, 30)).monthly_average).to be_nil
    activity(amount: 128_500, occurred_on: Date.new(2026, 9, 1))
    expect(summary(date: Date.new(2026, 9, 30)).monthly_average).to eq(14_278)
  end

  it "builds descending unique year options only from owned records and the reference year" do
    expect(described_class.available_years(user: user, date: date)).to eq([ 2026 ])
    activity(occurred_on: Date.new(2024, 1, 1))
    activity(occurred_on: Date.new(2024, 5, 1))
    activity(occurred_on: Date.new(2027, 1, 1))
    activity(owner: create(:user), occurred_on: Date.new(2023, 1, 1))
    expect(described_class.available_years(user: user, date: date)).to eq([ 2027, 2026, 2024 ])
    expect(summary(year: 2027).activity_count).to eq(0)
  end

  it "compares the current year through the same previous-year date with the same oshi" do
    activity(occurred_on: date)
    activity(occurred_on: Date.new(2025, 10, 6))
    activity(occurred_on: Date.new(2025, 10, 7))
    activity(occurred_on: Date.new(2025, 1, 1), oshis: [ second_oshi ])
    expect(summary.activity_change).to eq(-1)
    expect(summary(oshi: oshi).activity_change).to eq(0)
    expect(summary(oshi: second_oshi).activity_change).to eq(-1)
    activity(occurred_on: date, oshis: [ second_oshi ])
    activity(occurred_on: date, oshis: [ second_oshi ])
    expect(summary(oshi: second_oshi).activity_change).to eq(1)
  end

  it "compares full past years and handles leap-day previous years" do
    activity(occurred_on: Date.new(2025, 12, 31))
    activity(occurred_on: Date.new(2024, 12, 31))
    expect(summary(year: 2025).activity_change).to eq(0)
    activity(occurred_on: Date.new(2023, 2, 28))
    activity(occurred_on: Date.new(2023, 3, 1))
    expect(summary(date: Date.new(2024, 2, 29)).previous_activity_count).to eq(1)
  end

  it "calculates rounded category percentages without duplicating selected common activities" do
    activity(oshis: [ oshi, second_oshi ])
    activity(activity_type: "配信視聴")
    activity(activity_type: "グッズ購入")
    result = summary(oshi: oshi)
    expect(result.categories).to eq([
      { name: "ライブ・イベント", count: 1, percentage: 33 },
      { name: "配信視聴", count: 1, percentage: 33 },
      { name: "グッズ購入", count: 1, percentage: 33 }
    ])
    expect(summary(oshi: second_oshi).categories).to eq([ { name: "ライブ・イベント", count: 1, percentage: 100 } ])
  end

  it "sorts per-oshi counts by count, name, then id, retaining zero-count registrations" do
    third = create(:oshi, name: "推しA")
    create(:user_oshi, user: user, oshi: third)
    activity(oshis: [ second_oshi ])
    expect(summary.per_oshi.map { |row| row[:oshi] }).to eq([ second_oshi, oshi, third ])
  end

  it "keeps all current fixed costs independent of activity filters and associations" do
    create(:subscription, user: user, amount: 1000)
    create(:subscription, user: user, amount: 1000, oshis: [ oshi, second_oshi ], started_on: date, ended_on: date)
    create(:subscription, :yearly, user: user, amount: 6000, oshis: [ second_oshi ])
    create(:subscription, user: user, amount: 9000, started_on: date + 1)
    create(:subscription, :yearly, user: user, amount: 9000, ended_on: date - 1)
    create(:subscription, amount: 90_000)
    result = summary(year: 2025, oshi: oshi)
    expect(result.monthly_fixed_cost).to eq(2000)
    expect(result.yearly_fixed_cost).to eq(6000)
    expect(result.activity_amount).to eq(0)
  end

  it "excludes other users' activities, histories and subscriptions even for shared oshis" do
    other = create(:user)
    activity(owner: other, amount: 100_000)
    create(:subscription, user: other, amount: 90_000, oshis: [ oshi ])
    result = summary(oshi: oshi)
    expect(result.activity_count).to eq(0)
    expect(result.activity_amount).to eq(0)
    expect(result.per_oshi.first[:count]).to eq(0)
    expect(result.history).to eq("2023年から → 現在")
    expect(result.monthly_fixed_cost).to eq(0)
  end

  it "rejects an oshi that is not registered to the injected user" do
    expect { summary(oshi: create(:oshi, :approved)) }.to raise_error(ArgumentError)
  end

  describe "history" do
    [
      [ "2023", "2025", "2023年から → 2025年まで" ],
      [ "2023/05", "2025/07", "2023年5月から → 2025年7月まで" ],
      [ "2023", "2025/07", "2023年から → 2025年7月まで" ],
      [ "2023/05", nil, "2023年5月から → 現在" ],
      [ nil, "2025", "開始時期未設定 → 2025年まで" ],
      [ nil, nil, "開始時期未設定 → 現在" ]
    ].each do |started, ended, text|
      it "preserves precision for #{started.inspect}/#{ended.inspect}" do
        user.user_oshis.find_by!(oshi: oshi).update!(started_period: started, ended_period: ended)
        expect(summary(oshi: oshi).history).to eq(text)
      end
    end

    it "uses only the sole registration, guides multiple registrations, and handles no registrations" do
      expect(summary.history).to eq("推しを選択すると推し歴を確認できます")
      user.user_oshis.find_by!(oshi: second_oshi).destroy!
      expect(summary.history).to eq("2023年から → 現在")
      user.user_oshis.find_by!(oshi: oshi).destroy!
      expect(summary.history).to eq("推しが登録されていません")
    end

    it "shows the original start after restarting without inventing an absence duration" do
      record = user.user_oshis.find_by!(oshi: oshi)
      record.update!(started_period: "2020/05", ended_period: "2024")
      record.update!(ended_period: nil)
      expect(summary(oshi: oshi).history).to eq("2020年5月から → 現在")
    end
  end

  describe "highlight" do
    it "compares the last three calendar months with the preceding three" do
      expect(summary.highlight_periods).to eq(recent: Date.new(2026, 8, 1)..date, previous: Date.new(2026, 5, 1)..Date.new(2026, 7, 31))
      expect(summary(year: 2025).highlight_periods).to eq(recent: Date.new(2025, 10, 1)..Date.new(2025, 12, 31), previous: Date.new(2025, 7, 1)..Date.new(2025, 9, 30))
      january = summary(date: Date.new(2026, 1, 15))
      expect(january.highlight_periods[:recent]).to eq(Date.new(2025, 11, 1)..Date.new(2026, 1, 15))
    end

    it "reports the largest unrounded share increase and resolves ties by category definition order" do
      activity(occurred_on: Date.new(2026, 7, 31), activity_type: "その他")
      activity(occurred_on: Date.new(2026, 8, 1), activity_type: "配信視聴")
      activity(occurred_on: date)
      activity(occurred_on: date + 1, activity_type: "グッズ購入")
      activity(owner: create(:user), occurred_on: date, activity_type: "配信視聴")
      expect(summary.highlight).to eq("最近3か月は「ライブ・イベント」の割合が増えています。")
    end

    it "reports a rising category while another falls, applying the same oshi to both periods" do
      activity(occurred_on: Date.new(2026, 5, 1))
      activity(occurred_on: date, activity_type: "配信視聴", oshis: [ oshi, second_oshi ])
      activity(occurred_on: Date.new(2026, 5, 1), activity_type: "その他", oshis: [ second_oshi ])
      expect(summary(oshi: oshi).highlight).to eq("最近3か月は「配信視聴」の割合が増えています。")
      expect(summary(oshi: second_oshi).highlight).to eq("最近3か月は「配信視聴」の割合が増えています。")
    end

    it "returns no highlight for either empty period or identical shares" do
      activity(occurred_on: date)
      expect(summary.highlight).to be_nil
      activity(occurred_on: Date.new(2026, 7, 31))
      expect(summary.highlight).to be_nil
      expect(summary(year: 2025).highlight).to be_nil
    end

    it "returns no highlight when only the previous period has activities" do
      activity(occurred_on: Date.new(2026, 5, 1))
      expect(summary.highlight).to be_nil
    end

    it "uses full final quarters for a past year" do
      activity(occurred_on: Date.new(2025, 9, 30), activity_type: "その他")
      activity(occurred_on: Date.new(2025, 12, 31))
      expect(summary(year: 2025).highlight).to eq("最近3か月は「ライブ・イベント」の割合が増えています。")
    end
  end
end
