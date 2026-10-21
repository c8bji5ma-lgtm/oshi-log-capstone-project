require "rails_helper"

RSpec.describe Cards::DrawingPrimitives do
  subject(:renderer) do
    Class.new do
      include Cards::DrawingPrimitives

      def solid(*args) = solid_canvas(*args)
      def glyph(*args) = glyph_image(*args)
      def ink(*args) = text_ink(*args)
    end.new
  end

  it "provides the same private primitives to every card renderer" do
    [ Cards::Photo, Cards::Memory, Cards::Data ].each do |renderer_class|
      expect(renderer_class.ancestors).to include(described_class)
    end
  end

  it "creates an sRGB solid canvas with the requested dimensions and colour" do
    canvas = renderer.solid(3, 2, [ 12, 34, 56 ])

    expect([ canvas.width, canvas.height, canvas.bands, canvas.interpretation ]).to eq([ 3, 2, 3, :srgb ])
    expect(canvas.getpoint(2, 1)).to eq([ 12.0, 34.0, 56.0 ])
  end

  it "renders escaped text and builds an sRGB ink layer with the requested colour" do
    mask = renderer.glyph("<b>推し</b>", 24)
    ink = renderer.ink(mask, [ 36, 52, 71 ])

    expect([ mask.width, mask.height ]).to all(be_positive)
    expect([ ink.width, ink.height, ink.bands, ink.interpretation ]).to eq([ mask.width, mask.height, 4, :srgb ])
    expect(ink.extract_band(0).min).to eq(36)
    expect(ink.extract_band(1).min).to eq(52)
    expect(ink.extract_band(2).min).to eq(71)
    expect(ink.extract_band(3).max).to be_positive
  end
end
