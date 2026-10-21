require "erb"
require "vips"

module Cards
  module DrawingPrimitives
    FONT_FILE = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"

    private
      def solid_canvas(width, height, colour)
        Vips::Image.black(width, height, bands: 3).new_from_image(colour).copy(interpretation: :srgb)
      end

      def glyph_image(value, size)
        Vips::Image.text(ERB::Util.html_escape(value), font: "Noto Sans CJK JP #{size}", fontfile: FONT_FILE, dpi: 72)
      end

      def text_ink(mask, colour)
        mask.new_from_image(colour).bandjoin(mask).copy(interpretation: :srgb)
      end
  end
end
