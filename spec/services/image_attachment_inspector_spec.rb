require "rails_helper"
require "ffi"
require_relative "../support/image_attachments"

RSpec.describe ImageAttachmentInspector do
  include ImageAttachments

  def blob_for(bytes, filename: "image.png", content_type: "image/png")
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes), filename: filename, content_type: content_type, identify: false
    )
  end

  it "accepts the exact pixel boundary and returns the original bytes" do
    bytes = flat_png(4000, 3125)
    expect(described_class.read(blob_for(bytes))).to eq(bytes)
  end

  it "accepts a thin image at the exact dimension boundary" do
    bytes = flat_png(4096, 1)
    expect(described_class.read(blob_for(bytes))).to eq(bytes)
  end

  it "rejects a small upload whose header exceeds the maximum dimension" do
    bytes = flat_png(4097, 100)
    expect(bytes.bytesize).to be < 100.kilobytes
    expect { described_class.read(blob_for(bytes)) }.to raise_error(described_class::DimensionsExceeded)
  end

  it "rejects a small upload whose header exceeds the total pixel limit" do
    bytes = flat_png(4000, 3126)
    expect(bytes.bytesize).to be < 100.kilobytes
    expect { described_class.read(blob_for(bytes)) }.to raise_error(described_class::DimensionsExceeded)
  end

  it "accepts EXIF orientation without decoding or modifying the original" do
    image = Vips::Image.black(4032, 3024, bands: 3).copy
    image.set_type(GObject::GINT_TYPE, "orientation", 6)
    bytes = image.write_to_buffer(".jpg", Q: 80, strip: false)
    loaded = Vips::Image.new_from_buffer(bytes, "")
    expect(loaded.get("orientation")).to eq(6)
    expect(described_class.read(blob_for(bytes, filename: "oriented.jpg", content_type: "image/jpeg"))).to eq(bytes)
  end

  it "accepts an ICC-bearing JPEG" do
    lcms = Module.new do
      extend FFI::Library
      ffi_lib "liblcms2.so.2"
      attach_function :cmsCreate_sRGBProfile, [], :pointer
      attach_function :cmsSaveProfileToMem, [ :pointer, :pointer, :pointer ], :int
      attach_function :cmsCloseProfile, [ :pointer ], :void
    end
    pointer = lcms.cmsCreate_sRGBProfile
    size_pointer = FFI::MemoryPointer.new(:uint32)
    expect(lcms.cmsSaveProfileToMem(pointer, nil, size_pointer)).not_to eq(0)
    profile_pointer = FFI::MemoryPointer.new(:char, size_pointer.read_uint32)
    expect(lcms.cmsSaveProfileToMem(pointer, profile_pointer, size_pointer)).not_to eq(0)
    profile = profile_pointer.read_bytes(size_pointer.read_uint32)
    lcms.cmsCloseProfile(pointer)
    pointer = nil

    image = Vips::Image.black(64, 64, bands: 3).copy
    image.set_type(Vips::BLOB_TYPE, "icc-profile-data", profile)
    bytes = image.write_to_buffer(".jpg", Q: 80, strip: false)
    loaded = Vips::Image.new_from_buffer(bytes, "")
    expect(loaded.get("icc-profile-data").byteslice(36, 4)).to eq("acsp")
    expect(described_class.read(blob_for(bytes, filename: "profile.jpg", content_type: "image/jpeg"))).to eq(bytes)
  ensure
    lcms&.cmsCloseProfile(pointer) if pointer && !pointer.null?
  end

  it "accepts a true 16-bit PNG" do
    bytes = flat_png(64, 64, format: :ushort)
    expect(Vips::Image.new_from_buffer(bytes, "").format).to eq(:ushort)
    expect(described_class.read(blob_for(bytes))).to eq(bytes)
  end

  it "rejects a corrupt image without exposing decoder details" do
    bytes = ImageAttachmentInspector::PNG_SIGNATURE + "broken"
    expect { described_class.read(blob_for(bytes)) }.to raise_error(described_class::Invalid)
  end
end
