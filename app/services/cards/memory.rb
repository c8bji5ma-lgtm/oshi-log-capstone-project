require "digest"
require "json"
require "vips"

module Cards
  class Memory
    include DrawingPrimitives

    WIDTH = 1600
    HEIGHT = 1000
    PHOTO_WIDTH = 424
    PHOTO_HEIGHT = 400
    XS = { 1 => [ 568 ], 2 => [ 320, 816 ], 3 => [ 72, 568, 1064 ] }.freeze
    class InvalidSettings < StandardError; end

    def self.candidates(user)
      user.activities.where(occurred_on: ..Date.current)
        .order(occurred_on: :desc, created_at: :desc, id: :desc)
    end

    # This validation is also applied to settings recovered from signed receipts.
    def self.settings(input)
      raise InvalidSettings unless input.is_a?(Hash) && (input.keys.map(&:to_s) - %w[activity_ids image_attachment_ids crops]).empty?
      input = input.stringify_keys
      ids = input["activity_ids"]
      images = input["image_attachment_ids"]
      crops = input["crops"]
      raise InvalidSettings unless ids.is_a?(Array) && ids.length.between?(1, 3) && ids.uniq.length == ids.length && ids.all? { |id| valid_id?(id) }
      raise InvalidSettings unless images.is_a?(Array) && images.length == ids.length && images.all? { |id| id == "" || valid_id?(id) }
      raise Crop::Invalid unless crops.is_a?(Array) && crops.length == ids.length

      { activity_ids: ids, image_attachment_ids: images, crops: crops.map { |crop| Crop.normalize(crop) } }
    end

    def self.valid_id?(value)
      value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,18}\z/) && value.to_i <= 2**63 - 1
    end
    private_class_method :valid_id?

    def initialize(user:, **input)
      settings = self.class.settings(input)
      @profile = Profile.find_by(user_id: user.id) || raise(Photo::ProfileRequired)
      records = self.class.candidates(user).where(id: settings[:activity_ids])
        .includes(:oshis, :activity_oshis, images_attachments: :blob).index_by { |activity| activity.id.to_s }
      raise ActiveRecord::RecordNotFound unless records.length == settings[:activity_ids].length
      @activities = settings[:activity_ids].map { |id| records.fetch(id) }
      @attachments = @activities.each_with_index.map do |activity, index|
        images = activity.images_attachments.sort_by(&:id)
        id = settings[:image_attachment_ids][index]
        if id.empty?
          raise InvalidSettings unless images.empty?
          nil
        else
          images.find { |image| image.id.to_s == id } || raise(ActiveRecord::RecordNotFound)
        end
      end
      @crops = settings[:crops]
      @image_bytes = {}
      @attachments.each_with_index do |attachment, index|
        if attachment
          source = Vips::Image.new_from_buffer(image_bytes(attachment), "", access: :sequential, fail_on: :error).autorot
          Crop.geometry(image_width: source.width, image_height: source.height,
            width: PHOTO_WIDTH, height: PHOTO_HEIGHT, crop: @crops[index])
        else
          raise Crop::Invalid unless @crops[index] == Crop::DEFAULT
        end
      end
    rescue Vips::Error
      raise Photo::InvalidImage
    end

    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate([
        [ @profile.id, @profile.display_name, @profile.updated_at.iso8601(6) ],
        @activities.each_with_index.map do |activity, index|
          attachment = @attachments[index]
          [ activity.id, activity.occurred_on.iso8601, activity.title, activity.activity_type, activity.updated_at.iso8601(6),
            activity.activity_oshis.sort_by(&:id).map { |link| [ link.id, link.oshi_id ] },
            activity.oshis.sort_by(&:id).map { |oshi| [ oshi.id, oshi.name, oshi.updated_at.iso8601(6) ] },
            activity.images_attachments.sort_by(&:id).map { |image| [ image.id, image.blob_id ] },
            ([ attachment.id, attachment.blob.id, attachment.blob.key, attachment.blob.byte_size,
               Digest::SHA256.hexdigest(image_bytes(attachment)) ] if attachment) ]
        end
      ]))
    end

    def render
      raise Photo::FontUnavailable unless File.file?(Photo::FONT_FILE)
      canvas = solid_canvas(WIDTH, HEIGHT, [ 251, 243, 230 ])
      canvas = text(canvas, @profile.display_name, x: 72, y: 72, width: 1456, size: 56, limit: 20, max_lines: 1, line_height: 76)
      @activities.each_with_index do |activity, index|
        x = XS.fetch(@activities.length)[index]
        canvas = canvas.composite(solid_canvas(464, 680, [ 255, 253, 249 ]), :over, x: x, y: 194)
        # Paper tape stays outside the image and text areas.
        canvas = canvas.composite(solid_canvas(120, 12, [ 230, 201, 184 ]), :over, x: x + 172, y: 194)
        canvas = picture(canvas, @attachments[index], @crops[index], x + 20)
        canvas = text(canvas, activity.occurred_on.strftime("%Y.%m.%d"), x: x + 20, y: 633, width: 424, size: 24, limit: 10, max_lines: 1, line_height: 34)
        canvas = text(canvas, activity.title, x: x + 20, y: 678, width: 424, size: 32, limit: 24, max_lines: 2, line_height: 44)
        canvas = text(canvas, activity.activity_type, x: x + 20, y: 786, width: 424, size: 23, limit: 50, max_lines: 1, line_height: 32)
        names = activity.oshis.sort_by(&:id).map(&:name).join("・")
        canvas = text(canvas, names, x: x + 20, y: 828, width: 424, size: 23, limit: nil, max_lines: 1, line_height: 32)
      end
      canvas = text(canvas, "OshiLog", x: 72, y: 924, width: 1456, size: 24, limit: 20, max_lines: 1, line_height: 34)
      canvas = canvas.flatten(background: [ 251, 243, 230 ]) if canvas.has_alpha?
      canvas.write_to_buffer(".png", compression: 6, strip: true)
    rescue Vips::Error, ArgumentError
      raise Photo::InvalidImage
    end

    private
      def image_bytes(attachment)
        @image_bytes[attachment.blob_id] ||= ImageSource.read(attachment.blob)
      end

      def picture(canvas, attachment, crop, x)
        if attachment
          source = Vips::Image.new_from_buffer(image_bytes(attachment), "", access: :sequential, fail_on: :error).autorot.colourspace(:srgb)
          geometry = Crop.geometry(image_width: source.width, image_height: source.height, width: PHOTO_WIDTH, height: PHOTO_HEIGHT, crop: crop)
          image = source.resize(geometry[:scale]).crop(geometry[:left], geometry[:top], PHOTO_WIDTH, PHOTO_HEIGHT)
          canvas.composite(image, :over, x: x, y: 214)
        else
          raise Crop::Invalid unless crop == Crop::DEFAULT
          canvas = canvas.composite(solid_canvas(PHOTO_WIDTH, PHOTO_HEIGHT, [ 235, 226, 214 ]), :over, x: x, y: 214)
          canvas = canvas.composite(solid_canvas(72, 8, [ 218, 189, 165 ]), :over, x: x + 176, y: 378)
          text(canvas, "写真なし", x: x + 112, y: 414, width: 200, size: 28, limit: 10, max_lines: 1, line_height: 40)
        end
      end

      def text(canvas, value, x:, y:, width:, size:, limit:, max_lines:, line_height:)
        value = value.gsub(/\r\n?/, "\n").tr("\n", " ")
        raise Photo::InvalidImage unless value.valid_encoding? && !value.include?("\0")
        return canvas if value.match?(/\A[[:space:]]*\z/)

        # Walk graphemes lazily: even very large name lists stop at the visible edge.
        lines = [ "" ]
        count = 0
        truncated = false
        value.each_grapheme_cluster do |cluster|
          if limit && count >= limit
            truncated = true
            break
          end
          if glyph_image(lines.last + cluster, size).width <= width
            lines[-1] += cluster
          elsif lines.length < max_lines && glyph_image(cluster, size).width <= width
            lines << cluster
          else
            truncated = true
            break
          end
          count += 1
        end
        if truncated
          last = lines.last.each_grapheme_cluster.to_a
          last.pop while last.any? && (glyph_image(last.join + "…", size).width > width ||
            (limit && (lines[0...-1].join + last.join + "…").each_grapheme_cluster.count > limit))
          lines[-1] = last.join + "…"
        end
        lines.each_with_index do |line, index|
          next if line.empty?
          mask = glyph_image(line, size)
          raise Photo::InvalidImage if mask.width > width || mask.height > line_height
          ink = text_ink(mask, [ 66, 51, 44 ])
          canvas = canvas.composite(ink, :over, x: x, y: y + index * line_height)
        end
        canvas
      end
  end
end
