module Activities
  class PhotoPreview
    MAX_EDGE = 256

    def self.call(blob)
      bytes = ImageAttachmentInspector.read(blob)
      image = Vips::Image.new_from_buffer(bytes, "", access: :sequential, fail_on: :error).autorot
      image.thumbnail_image(MAX_EDGE, height: MAX_EDGE, size: :down)
        .write_to_buffer(".webp", Q: 76, strip: true)
    end
  end
end
