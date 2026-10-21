module Cards
  # Read and validate originals without writing blobs or attachment metadata.
  class ImageSource
    def self.read(blob)
      new.read(blob)
    end

    def read(blob)
      ImageAttachmentInspector.read(blob)
    rescue ImageAttachmentInspector::DimensionsExceeded
      raise Photo::ImageDimensionsExceeded
    rescue ImageAttachmentInspector::Invalid
      raise Photo::InvalidImage
    end
  end
end
