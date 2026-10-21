require "rails_helper"

RSpec.describe Cards::RenderGate do
  it "allows only one concurrent render and releases the gate afterward" do
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      described_class.with do
        entered << true
        release.pop
      end
    end
    entered.pop

    expect { described_class.with { :unreachable } }.to raise_error(described_class::Busy)
    release << true
    holder.join

    expect(described_class.with { :available }).to eq(:available)
  ensure
    release << true if holder&.alive?
    holder&.join
  end

  it "releases the gate when rendering raises" do
    expect { described_class.with { raise "render failed" } }.to raise_error("render failed")
    expect(described_class.with { :available }).to eq(:available)
  end
end
