require "digest"
require "vips"

class ImageAttachmentInspector
  CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_BYTE_SIZE = 10 * 1024 * 1024
  MAX_DIMENSION = 2560
  MAX_PIXELS = 5_000_000
  PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
  INSPECTED_IVAR = :@image_attachment_inspected

  class Invalid < StandardError; end
  class DimensionsExceeded < Invalid; end

  def self.read(blob)
    new.read(blob)
  end

  def self.read_attachable(attachable, blob)
    new.read_attachable(attachable, blob)
  end

  def self.inspected?(blob)
    blob.instance_variable_defined?(INSPECTED_IVAR)
  end

  def read(blob)
    raise Invalid unless CONTENT_TYPES.include?(blob.content_type)
    raise Invalid unless blob.byte_size.positive? && blob.byte_size <= MAX_BYTE_SIZE

    bytes = blob.download
    validate_bytes!(bytes, blob)
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError, Vips::Error, Errno::ENOENT, IOError
    raise Invalid
  end

  def read_attachable(attachable, blob)
    return read(blob) if attachable.is_a?(ActiveStorage::Blob) || attachable.is_a?(String)

    io = if attachable.is_a?(Hash)
      attachable.fetch(:io)
    else
      attachable.respond_to?(:open) ? attachable.open : attachable
    end
    position = io.pos if io.respond_to?(:pos)
    io.rewind
    bytes = io.read(MAX_BYTE_SIZE + 1)
    validated = validate_bytes!(bytes, blob)
    blob.instance_variable_set(INSPECTED_IVAR, true)
    validated
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError, Vips::Error, Errno::ENOENT, IOError, KeyError
    raise Invalid
  ensure
    io.seek(position) if io&.respond_to?(:seek) && position
  end

  private
    def validate_bytes!(bytes, blob)
      raise Invalid unless CONTENT_TYPES.include?(blob.content_type)
      raise Invalid unless blob.byte_size.positive? && blob.byte_size <= MAX_BYTE_SIZE
      raise Invalid unless bytes.bytesize == blob.byte_size
      raise Invalid unless Digest::MD5.base64digest(bytes) == blob.checksum

      validate_format!(bytes, blob.content_type)
      image = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error)
      width, height = oriented_dimensions(image)
      raise Invalid unless width.positive? && height.positive?
      raise Invalid if image.get_typeof("n-pages").positive? && image.get("n-pages") != 1
      raise DimensionsExceeded if width > MAX_DIMENSION || height > MAX_DIMENSION || width * height > MAX_PIXELS

      bytes
    end

    def oriented_dimensions(image)
      orientation = image.get_typeof("orientation").positive? ? image.get("orientation") : 1
      [ 5, 6, 7, 8 ].include?(orientation) ? [ image.height, image.width ] : [ image.width, image.height ]
    end

    def validate_format!(bytes, type)
      case type
      when "image/jpeg"
        raise Invalid unless bytes.start_with?("\xff\xd8\xff".b)
      when "image/png"
        raise Invalid unless bytes.start_with?(PNG_SIGNATURE)
        reject_animated_png!(bytes)
      when "image/webp"
        raise Invalid unless bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP"
        reject_animated_webp!(bytes)
      end
    end

    def reject_animated_png!(bytes)
      offset = PNG_SIGNATURE.bytesize
      while offset + 12 <= bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        kind = bytes.byteslice(offset + 4, 4)
        raise Invalid if kind == "acTL" || offset + length + 12 > bytes.bytesize
        offset += length + 12
        return if kind == "IEND"
      end
      raise Invalid
    end

    def reject_animated_webp!(bytes)
      offset = 12
      while offset + 8 <= bytes.bytesize
        kind = bytes.byteslice(offset, 4)
        length = bytes.byteslice(offset + 4, 4).unpack1("V")
        raise Invalid if %w[ANIM ANMF].include?(kind) || offset + length + 8 > bytes.bytesize
        offset += 8 + length + length % 2
      end
      raise Invalid unless offset == bytes.bytesize
    end
end
