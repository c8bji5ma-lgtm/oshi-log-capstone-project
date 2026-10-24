require "digest"
require "json"
require "vips"

module Cards
  # Photo-only renderer. Sources are read without modifying their stored bytes.
  class Photo
    include DrawingPrimitives

    WIDTH = 1600
    HEIGHT = 1000
    FONT_FILE = DrawingPrimitives::FONT_FILE
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

    # Dimensions and font sizes follow STEP 6. Internal XY remain provisional:
    # phase 1's approved one-person layout and phase 2-1's supplied coordinates.
    LAYOUTS = {
      1 => { width: 496, height: 620, xs: [ 48 ].freeze, name_y: 176, name_size: 54, limit: 32 },
      2 => { width: 416, height: 520, xs: [ 372, 812 ].freeze, name_y: 704, name_size: 36, limit: 32 },
      3 => { width: 416, height: 520, xs: [ 152, 592, 1032 ].freeze, name_y: 704, name_size: 34, limit: 24 },
      4 => { width: 352, height: 440, xs: [ 72, 440, 808, 1176 ].freeze, name_y: 628, name_size: 32, limit: 20 }
    }.transform_values(&:freeze).freeze
    SINGLE_COLLAGE_LAYOUTS = {
      main: { x: 48, y: 176, width: 496, height: 620 },
      supplement_one: { x: 568, y: 310, width: 984, height: 486 },
      supplement_left: { x: 568, y: 310, width: 480, height: 486 },
      supplement_right: { x: 1072, y: 310, width: 480, height: 486 }
    }.transform_values(&:freeze).freeze

    class InvalidImage < StandardError; end
    class ImageDimensionsExceeded < InvalidImage; end
    class FontUnavailable < StandardError; end
    class ProfileRequired < StandardError; end

    # Omitted attachment IDs retain the legacy representative-image API. With
    # explicit IDs, each frame is either an owner/attachment pair or ""/"".
    def self.validate_image_ids!(owners, attachments)
      raise ArgumentError unless attachments.is_a?(Array) && attachments.length == owners.length
      raise ArgumentError unless attachments.each_with_index.all? do |id, index|
        owners[index] == "" ? id == "" : id.is_a?(String) && id.match?(/\A[1-9][0-9]{0,18}\z/) && id.to_i <= 2**63 - 1
      end
    end

    def initialize(user:, user_oshi_ids:, image_user_oshi_ids:, show_introduction: true, crops: nil, image_attachment_ids: nil,
      collage_image_attachment_ids: nil, collage_crops: nil)
      @profile = Profile.find_by(user_id: user.id) || raise(ProfileRequired)
      raise ArgumentError unless image_user_oshi_ids.is_a?(Array) && image_user_oshi_ids.length == user_oshi_ids.length
      @explicit_images = !image_attachment_ids.nil? || !collage_image_attachment_ids.nil?
      self.class.validate_image_ids!(image_user_oshi_ids, image_attachment_ids) unless image_attachment_ids.nil?
      records = user.user_oshis.includes(:oshi, representative_image_attachment: :blob, library_images_attachments: :blob)
        .where(id: user_oshi_ids).index_by { |record| record.id.to_s }
      raise ActiveRecord::RecordNotFound unless records.length == user_oshi_ids.length
      @user_oshis = user_oshi_ids.map { |id| records.fetch(id) }
      @image_owners = image_user_oshi_ids.map do |id|
        records.fetch(id) { raise ActiveRecord::RecordNotFound } if id.present?
      end
      @image_attachments = @image_owners.each_with_index.map do |owner, index|
        next unless owner
        if image_attachment_ids
          owner.image_library.find { |image| image.id.to_s == image_attachment_ids[index] } || raise(ActiveRecord::RecordNotFound)
        else
          owner.representative_image.attachment
        end
      end
      @image_bytes = {}
      @show_introduction = show_introduction
      raise Crop::Invalid unless crops.nil? || (crops.is_a?(Array) && crops.length == @user_oshis.length)
      @crops = (crops || Array.new(@user_oshis.length, Crop::DEFAULT)).map { |crop| Crop.normalize(crop) }
      initialize_single_collage(collage_image_attachment_ids, collage_crops)
    end

    def fingerprint
      validate_crops!
      Digest::SHA256.hexdigest(JSON.generate([
        @profile.id, @profile.display_name, @profile.updated_at.iso8601(6),
        (@profile.introduction if @show_introduction),
        @user_oshis.map { |record| [ record.id, record.oshi.id, record.oshi.name, record.oshi.updated_at.iso8601(6) ] },
        image_fingerprint
      ]))
    end

    def render
      raise FontUnavailable unless File.file?(FONT_FILE)

      canvas = solid_canvas(WIDTH, HEIGHT, [ 255, 255, 255 ])
      if @collage_image_attachments
        canvas = render_single_collage(canvas)
      else
        layout = LAYOUTS.fetch(@user_oshis.length)
        @user_oshis.each_with_index do |record, index|
          x = layout[:xs][index]
          canvas = picture(canvas, @image_owners[index], attachment: @image_attachments[index], crop: @crops[index],
            x: x, y: 176, width: layout[:width], height: layout[:height])
          canvas = text(canvas, record.oshi.name, x: single? ? 568 : x, y: layout[:name_y],
            width: single? ? 984 : layout[:width], size: layout[:name_size], limit: layout[:limit],
            max_lines: 2, line_height: single? ? 66 : 40)
        end
      end
      canvas = text(canvas, @profile.display_name, x: 48, y: 48, width: 1200,
        size: 32, limit: 20, max_lines: 1, line_height: 40)
      if @show_introduction
        canvas = text(canvas, @profile.introduction.to_s, x: 48, y: 824, width: 1504,
          size: 32, limit: 80, max_lines: 2, line_height: 40, multiline: true)
      end
      canvas = text(canvas, "OshiLog", x: 1400, y: 112, width: 152,
        size: 24, limit: 10, max_lines: 1, line_height: 32)
      canvas = canvas.flatten(background: [ 255, 255, 255 ]) if canvas.has_alpha?
      canvas.write_to_buffer(".png", compression: 6, strip: true)
    rescue Vips::Error, ArgumentError
      raise InvalidImage
    end

    private
      # Fingerprints are checked on download without rendering again. Validate
      # restored settings against the actual oriented image in that path too.
      def validate_crops!
        return validate_collage_crops! if @collage_image_attachments

        layout = LAYOUTS.fetch(@user_oshis.length)
        @image_attachments.each_with_index do |attachment, index|
          bytes = attachment && image_bytes(attachment)
          if bytes
            source = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error).autorot
            Crop.geometry(image_width: source.width, image_height: source.height,
              width: layout[:width], height: layout[:height], crop: @crops[index])
          else
            raise Crop::Invalid unless @crops[index] == Crop::DEFAULT
          end
        end
      rescue Vips::Error
        raise InvalidImage
      end

      def single?
        @user_oshis.length == 1
      end

      def initialize_single_collage(attachment_ids, crops)
        if attachment_ids.nil? && crops.nil?
          @collage_image_attachments = nil
          return
        end
        raise ArgumentError unless single? && attachment_ids.is_a?(Array) && attachment_ids.length == 3
        raise Crop::Invalid unless crops.is_a?(Array) && crops.length == 3
        raise ArgumentError unless attachment_ids.all? do |id|
          id == "" || id.is_a?(String) && id.match?(/\A[1-9][0-9]{0,18}\z/) && id.to_i <= 2**63 - 1
        end

        library = @user_oshis.first.image_library.index_by { |image| image.id.to_s }
        @collage_image_attachments = attachment_ids.map do |id|
          id == "" ? nil : library.fetch(id) { raise ActiveRecord::RecordNotFound }
        end
        @collage_crops = crops.map { |crop| Crop.normalize(crop) }
      end

      def image_fingerprint
        unless @collage_image_attachments
          return @image_owners.each_with_index.map do |owner, index|
            [ owner.id, image_identity(@image_attachments[index]) ] if owner
          end
        end

        @collage_image_attachments.map { |attachment| image_identity(attachment) }
      end

      def collage_layouts
        visible_supplements = @collage_image_attachments.drop(1).each_index.select do |index|
          @collage_image_attachments[index + 1]
        end
        layouts = [ SINGLE_COLLAGE_LAYOUTS[:main], nil, nil ]
        if visible_supplements.length == 1
          layouts[visible_supplements.first + 1] = SINGLE_COLLAGE_LAYOUTS[:supplement_one]
        elsif visible_supplements.length == 2
          layouts[visible_supplements[0] + 1] = SINGLE_COLLAGE_LAYOUTS[:supplement_left]
          layouts[visible_supplements[1] + 1] = SINGLE_COLLAGE_LAYOUTS[:supplement_right]
        end
        layouts
      end

      def validate_collage_crops!
        collage_layouts.each_with_index do |layout, index|
          attachment = @collage_image_attachments[index]
          unless attachment
            raise Crop::Invalid unless @collage_crops[index] == Crop::DEFAULT
            next
          end
          bytes = image_bytes(attachment)
          source = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error).autorot
          Crop.geometry(image_width: source.width, image_height: source.height,
            width: layout[:width], height: layout[:height], crop: @collage_crops[index])
        end
      rescue Vips::Error
        raise InvalidImage
      end

      def render_single_collage(canvas)
        owner = @user_oshis.first
        layouts = collage_layouts
        main_owner = @collage_image_attachments.first ? owner : nil
        canvas = picture(canvas, main_owner, attachment: @collage_image_attachments.first,
          crop: @collage_crops.first, **layouts.first)
        @collage_image_attachments.drop(1).each_with_index do |attachment, index|
          next unless attachment
          canvas = picture(canvas, owner, attachment:, crop: @collage_crops[index + 1], **layouts[index + 1])
        end
        layout = LAYOUTS.fetch(1)
        text(canvas, owner.oshi.name, x: 568, y: layout[:name_y], width: 984,
          size: layout[:name_size], limit: layout[:limit], max_lines: 2, line_height: 66)
      end

      def picture(canvas, owner, attachment:, crop:, x:, y:, width:, height:)
        bytes = image_bytes(attachment) if attachment
        if bytes
          source = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error).autorot.colourspace(:srgb)
          geometry = Crop.geometry(image_width: source.width, image_height: source.height, width: width, height: height, crop: crop)
          resized = source.resize(geometry[:scale])
          photo = resized.crop(geometry[:left], geometry[:top], width, height)
          canvas.composite(photo, :over, x:, y:)
        else
          raise Crop::Invalid unless crop == Crop::DEFAULT

          placeholder = solid_canvas(width, height, [ 240, 243, 246 ])
          canvas = canvas.composite(placeholder, :over, x:, y:)
          placeholder_y = single? && x == 48 && y == 176 && width == 496 && height == 620 ? 460 : y + (height - 32) / 2
          text(canvas, owner ? "画像未登録" : "画像を使用しない", x: x + (width - 272) / 2,
            y: placeholder_y,
            width: 272, size: 24, limit: 20, max_lines: 1, line_height: 32)
        end
      end

      def image_identity(attachment)
        return nil unless attachment

        blob = attachment.blob
        unless @explicit_images
          return [ attachment.id, blob.id, blob.key, blob.byte_size, Digest::SHA256.hexdigest(image_bytes(attachment)) ]
        end
        [ attachment.id, attachment.record_type, attachment.record_id, attachment.name,
          blob.id, blob.key, blob.byte_size, blob.checksum, Digest::SHA256.hexdigest(image_bytes(attachment)) ]
      end

      def image_bytes(attachment)
        blob = attachment.blob
        return @image_bytes[blob.id] if @image_bytes.key?(blob.id)
        @image_bytes[blob.id] = ImageSource.read(blob)
      end

      def text(canvas, value, x:, y:, width:, size:, limit:, max_lines:, line_height:, multiline: false)
        normalized = value.gsub(/\r\n?/, "\n")
        normalized = normalized.tr("\n", " ") unless multiline
        return canvas if normalized.match?(/\A[[:space:]]*\z/)
        raise InvalidImage unless normalized.valid_encoding? && !normalized.include?("\0")

        clusters = normalized.each_grapheme_cluster.take(limit + 1)
        truncated = clusters.length > limit
        clusters = clusters.take(limit)
        lines = [ "" ]
        clusters.each do |cluster|
          if cluster == "\n"
            if lines.length == max_lines
              truncated = true
              break
            end
            lines << ""
          elsif glyph_image(lines.last + cluster, size).width <= width
            lines[-1] += cluster
          elsif lines.length < max_lines && glyph_image(cluster, size).width <= width
            lines << cluster
          else
            truncated = true
            break
          end
        end
        if truncated
          last = lines.last.each_grapheme_cluster.to_a
          last.pop while last.any? && (glyph_image(last.join + "…", size).width > width ||
            (lines[0...-1].join + last.join + "…").each_grapheme_cluster.count > limit)
          lines[-1] = last.join + "…"
        end
        lines.each_with_index do |line, index|
          next if line.empty?
          mask = glyph_image(line, size)
          raise InvalidImage if mask.width > width || mask.height > line_height
          ink = text_ink(mask, [ 36, 52, 71 ])
          canvas = canvas.composite(ink, :over, x: x, y: y + index * line_height)
        end
        canvas
      end
  end
end
