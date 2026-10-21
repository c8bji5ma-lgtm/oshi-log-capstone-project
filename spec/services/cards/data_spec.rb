require "rails_helper"

RSpec.describe Cards::Data do
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, name: "推しA") }
  let(:second) { create(:oshi, name: "推しB") }
  let(:date) { Date.new(2026, 6, 15) }

  around { |example| travel_to(Time.zone.local(2026, 6, 15, 12)) { example.run } }
  before do
    create(:profile, user: user)
    create(:user_oshi, user: user, oshi: oshi)
    create(:user_oshi, user: user, oshi: second, ended_period: "2025")
  end

  def activity(oshis: [ oshi ], owner: user, **options)
    record = build(:activity, :without_oshis, user: owner, occurred_on: date, **options)
    oshis.each { |selected| UserOshi.find_or_create_by!(user: owner, oshi: selected) }
    Activities::Save.call(activity: record, oshi_ids: oshis.map(&:id))
  end

  def renderer(year: "2026", oshi_id: "")
    described_class.new(user: user, year: year, oshi_id: oshi_id)
  end

  it "uses Summary values without double-counting equal amounts or common activities and excludes future records and fixed costs" do
    activity(amount: 1000)
    activity(amount: 1000)
    activity(amount: 2000, oshis: [ oshi, second ])
    activity(amount: nil)
    activity(amount: 90000, occurred_on: date + 1)
    activity(amount: 90000, owner: create(:user))
    create(:subscription, user: user, amount: 90000)
    [ nil, oshi, second ].each do |selected|
      summary = OshiData::Summary.new(user: user, date: date, year: 2026, oshi: selected)
      stats = renderer(oshi_id: selected&.id.to_s).statistics
      expect(stats.values_at(:count, :amount, :recorded)).to eq([ summary.activity_count, summary.activity_amount, summary.amount_recorded? ])
      expect(stats[:months].reject { |row| row[:future] }.map { |row| row.slice(:month, :count) }).to eq(summary.monthly_activities)
    end
    expect(renderer.statistics.values_at(:count, :amount)).to eq([ 4, 4000 ])
    expect(renderer(oshi_id: oshi.id.to_s).statistics.values_at(:count, :amount)).to eq([ 4, 2000 ])
    expect(renderer(oshi_id: second.id.to_s).statistics.values_at(:count, :amount, :recorded)).to eq([ 1, 0, true ])
  end

  it "distinguishes no money, explicit zero, and a recorded common expense for a single oshi" do
    record = activity(amount: nil, oshis: [ oshi, second ])
    expect(renderer.statistics[:recorded]).to be(false)
    expect(renderer(oshi_id: second.id.to_s).statistics[:recorded]).to be(false)
    record.update!(amount: 0)
    expect(renderer.statistics.values_at(:amount, :recorded)).to eq([ 0, true ])
    record.update!(amount: 1000)
    expect(renderer(oshi_id: second.id.to_s).statistics.values_at(:amount, :recorded)).to eq([ 0, true ])
  end

  it "uses full past years, today for this year, and nil rather than zero for future months" do
    activity(occurred_on: Date.new(2025, 12, 31))
    activity(occurred_on: Date.new(2027, 1, 1))
    expect(renderer(year: "2025").statistics[:period_end]).to eq(Date.new(2025, 12, 31))
    expect(renderer(year: "2025").statistics[:months]).to eq((1..12).map { |month| { month: month, count: month == 12 ? 1 : 0, future: false } })
    expect(renderer.statistics[:period_end]).to eq(date)
    expect(renderer.statistics[:months].first(6)).to eq((1..6).map { |month| { month: month, count: 0, future: false } })
    expect(renderer.statistics[:months].last(6)).to eq((7..12).map { |month| { month: month, count: nil, future: true } })
    future = renderer(year: "2027").statistics
    expect(future[:period_end]).to eq(Date.new(2027, 12, 31))
    expect(future.values_at(:count, :amount, :recorded)).to eq([ 0, 0, false ])
    expect(future[:months]).to eq((1..12).map { |month| { month: month, count: nil, future: true } })
  end

  it "draws the approved panels and exact normalized bars without inventing nonzero or future bars" do
    activity(occurred_on: Date.new(2026, 1, 1))
    2.times { activity(occurred_on: Date.new(2026, 2, 1)) }
    png = renderer.render
    image = Vips::Image.new_from_buffer(png, "")
    expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
    expect(image.getpoint(72, 234).take(3)).to eq([ 252, 222, 237 ])
    expect(image.getpoint(827, 234).take(3)).to eq(described_class::PAPER)
    expect(image.getpoint(828, 234).take(3)).to eq([ 223, 237, 254 ])
    expect(image.getpoint(72, 436).take(3)).to eq(described_class::GRAPH)
    expect(image.getpoint(170, 659).take(3)).not_to eq(described_class::BAR_COLOUR)
    expect(image.getpoint(170, 660).take(3)).to eq(described_class::BAR_COLOUR)
    expect(image.getpoint(280, 539).take(3)).not_to eq(described_class::BAR_COLOUR)
    expect(image.getpoint(280, 540).take(3)).to eq(described_class::BAR_COLOUR)
    expect(image.getpoint(390, 779).take(3)).to eq(described_class::GRAPH)
    expect(image.getpoint(830, 600).take(3)).to eq(described_class::FUTURE)
    expect(image.getpoint(918, 600).take(3)).to eq(described_class::FUTURE)
    # A zero month in a full past year is real zero, not a future-month region.
    activity(occurred_on: Date.new(2025, 1, 1))
    past = Vips::Image.new_from_buffer(renderer(year: "2025").render, "")
    expect(past.getpoint(1380, 600).take(3)).to eq(described_class::GRAPH)
  end

  it "draws twelve month labels, visible Summary values, future guidance, and only the requested content" do
    activity(amount: 2000, memo: "秘密のメモ", place: "秘密の場所")
    service = renderer(oshi_id: oshi.id.to_s)
    calls = []
    allow(service).to receive(:text).and_wrap_original do |original, canvas, value, **options|
      calls << [ value, options ]
      original.call(canvas, value, **options)
    end
    service.render
    strings = calls.map(&:first)
    expect(strings).to include("1回", "2,000円", "推しA", "2026年", user.profile.display_name)
    expect(strings).to include(*(1..12).map { |month| "#{month}月" })
    expect(strings).to include("対象期間：2026.01.01〜2026.06.15")
    expect(strings).to include(a_string_including("複数推しの共通支出は含みません"))
    expect(strings).not_to include("秘密のメモ", "秘密の場所", "前年比較", "月平均支出", "推し歴")
    expect(calls.select { |value, _| value == "未来月" }.length).to eq(6)
    activity(occurred_on: Date.new(2027, 1, 1))
    future = renderer(year: "2027")
    future_text = []
    allow(future).to receive(:text).and_wrap_original do |original, canvas, value, **options|
      future_text << value
      original.call(canvas, value, **options)
    end
    expect { future.render }.not_to raise_error
    expect(future_text).to include(a_string_including("2027.01.01〜2027.12.31", "実績はまだありません"))
  end

  it "renders all-zero cards without registrations and distinguishes no recorded money" do
    user.user_oshis.destroy_all
    service = renderer
    expect(service.statistics.values_at(:count, :amount, :recorded)).to eq([ 0, 0, false ])
    text = []
    allow(service).to receive(:text).and_wrap_original do |original, canvas, value, **options|
      text << value
      original.call(canvas, value, **options)
    end
    expect { service.render }.not_to raise_error
    expect(text).to include("支出記録なし")
  end

  it "bounds graphemes, fonts and actual glyph width for long names and full large numeric amounts without changing data" do
    oshi.update!(name: "W👩‍👩‍👧‍👦é" * 20)
    user.profile.update!(display_name: "W" * 20)
    2.times { activity(amount: 2_000_000_000) }
    # Stress the renderer with an aggregate larger than an individual DB amount.
    allow_any_instance_of(OshiData::Summary).to receive(:activity_amount).and_return(18_000_000_000_000_000_000)
    names = [ oshi.reload.attributes, user.profile.reload.attributes ]
    service = renderer(oshi_id: oshi.id.to_s)
    widths = []
    allow(service).to receive(:glyph_image).and_wrap_original do |original, value, size|
      glyph = original.call(value, size)
      widths << [ value, size, glyph.width ]
      glyph
    end
    expect { service.render }.not_to raise_error
    number = widths.select { |value, _, _| value == "18,000,000,000,000,000,000円" }.last
    expect(number).to be_present
    expect(number[1]).to be < 64
    expect(number[2]).to be <= 652
    truncated = widths.select { |value, _, _| value.end_with?("…") }
    expect(truncated).not_to be_empty
    expect(truncated.last[0]).to match(/\A(?:W|👩‍👩‍👧‍👦|é)+…\z/)
    expect([ oshi.reload.attributes, user.profile.reload.attributes ]).to eq(names)
  end

  it "detects offsetting amount changes, date changes with unchanged total, link reclassification and midnight" do
    first = activity(amount: 1000)
    second_record = activity(amount: 2000)
    fingerprint = renderer.fingerprint
    first.update!(amount: 1500)
    second_record.update!(amount: 1500)
    expect(renderer.statistics.values_at(:count, :amount)).to eq([ 2, 3000 ])
    expect(renderer.fingerprint).not_to eq(fingerprint)
    fingerprint = renderer.fingerprint
    first.update!(occurred_on: date - 1)
    expect(renderer.fingerprint).not_to eq(fingerprint)
    filtered = renderer(oshi_id: oshi.id.to_s).fingerprint
    create(:activity_oshi, activity: first, oshi: second)
    expect(renderer(oshi_id: oshi.id.to_s).fingerprint).not_to eq(filtered)
    fingerprint = renderer.fingerprint
    travel 1.day
    expect(renderer.fingerprint).not_to eq(fingerprint)
  end
end
