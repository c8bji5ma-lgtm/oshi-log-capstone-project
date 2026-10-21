require "stringio"

module ImageAttachments
  def image_upload(filename = "image.png", size: nil)
    data = File.binread(Rails.root.join("spec/fixtures/files", filename))
    data = data.ljust(size, "\0") if size
    { io: StringIO.new(data), filename: filename }
  end

  def image_upload_data(data, filename: "image.png", content_type: "image/png")
    { io: StringIO.new(data), filename: filename, content_type: content_type, identify: false }
  end

  def flat_png(width, height, format: :uchar)
    image = Vips::Image.black(width, height, bands: 3).cast(format)
    options = { compression: 9, strip: false }
    options[:bitdepth] = 16 if format == :ushort
    image.write_to_buffer(".png", **options)
  end
end
