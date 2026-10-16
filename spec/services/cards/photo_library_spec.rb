require "rails_helper"
require "tmpdir"
require_relative "../../support/card_images"

RSpec.describe "Photo renderer library selection" do
  include CardImages
  let(:user) { create(:user) }
  let(:profile) { create(:profile, user: user) }
  let(:record) { create(:user_oshi, user: user) }

  around do |example|
    services, service = ActiveStorage::Blob.services, ActiveStorage::Blob.service
    Dir.mktmpdir("photo-library-render-") do |directory|
      disk = ActiveStorage::Service::DiskService.new(root: directory)
      disk.name = "test"
      ActiveStorage::Blob.services = { "test" => disk }
      ActiveStorage::Blob.service = disk
      example.run
    ensure
      ActiveStorage::Blob.services, ActiveStorage::Blob.service = services, service
    end
  end

  def renderer(records = [ record ], **settings)
    profile
    Cards::Photo.new(user: user, user_oshi_ids: records.map { |item| item.id.to_s },
      image_user_oshi_ids: Array.new(records.size, record.id.to_s), **settings)
  end

  def library_image(**options)
    bytes = coordinate_image(**options)
    record.library_images.attach(io: StringIO.new(bytes), filename: options[:orientation] ? "oriented.jpg" : "coordinates.png")
    record.reload.image_library.last
  end

  it "preserves the pre-library fingerprint for requests omitting attachment IDs" do
    profile
    bytes = attach_coordinates(record)
    attachment = record.representative_image.attachment
    blob = attachment.blob
    expected = Digest::SHA256.hexdigest(JSON.generate([
      profile.id, profile.display_name, profile.updated_at.iso8601(6), profile.introduction,
      [ [ record.id, record.oshi.id, record.oshi.name, record.oshi.updated_at.iso8601(6) ] ],
      [ [ record.id, [ attachment.id, blob.id, blob.key, blob.byte_size, Digest::SHA256.hexdigest(bytes) ] ] ]
    ]))
    expect(renderer.fingerprint).to eq(expected)
  end

  it "independently crops one selected library original in two fixed photo frames and reads it once" do
    image = library_image
    original = image.blob.reload.attributes
    bytes = image.download
    second = create(:user_oshi, user: user)
    crops = [ { x: 0.25, y: 0.35, zoom: 3 }, { x: 0.75, y: 0.65, zoom: 3 } ]
    expect(Cards::ImageSource).to receive(:read).with(image.blob).once.and_call_original
    card = renderer([ record, second ], image_attachment_ids: [ image.id.to_s ] * 2, crops: crops)
    card.fingerprint
    png = Vips::Image.new_from_buffer(card.render, "")
    expect(png.getpoint(580, 436).first).to be < png.getpoint(1020, 436).first
    [ 372, 812 ].each do |x|
      expect(png.getpoint(x - 1, 176).take(3)).to eq([ 255, 255, 255 ])
      expect(png.getpoint(x + 416, 176).take(3)).to eq([ 255, 255, 255 ])
    end
    expect(image.blob.reload.attributes).to eq(original)
    expect(image.download).to eq(bytes)
  end

  it "applies the existing orientation and crop formula to the selected library image" do
    image = library_image(orientation: 6)
    bytes = image.download
    crop = { x: 0.4, y: 0.6, zoom: 3 }
    source = Vips::Image.new_from_buffer(bytes, "").autorot.colourspace(:srgb)
    expected = source.resize(2.48).crop(347, 1029, 496, 620)
    png = renderer(image_attachment_ids: [ image.id.to_s ], crops: [ crop ]).render
    actual = Vips::Image.new_from_buffer(png, "").crop(48, 176, 496, 620)
    expect((actual - expected).abs.max).to eq(0)
    expect(image.download).to eq(bytes)
  end

  it "rejects disabled-frame crops, unsafe content and mismatched image owners" do
    image = library_image
    expect { renderer(image_user_oshi_ids: [ "" ], image_attachment_ids: [ "" ], crops: [ { x: 0.5, y: 0.5, zoom: 2 } ]).fingerprint }
      .to raise_error(Cards::Crop::Invalid)
    second = create(:user_oshi, user: user)
    expect { renderer([ record, second ], image_user_oshi_ids: [ second.id.to_s, "" ], image_attachment_ids: [ image.id.to_s, "" ]) }
      .to raise_error(ActiveRecord::RecordNotFound)
    image.blob.update!(content_type: "image/svg+xml")
    expect { renderer(image_attachment_ids: [ image.id.to_s ]).fingerprint }.to raise_error(Cards::Photo::InvalidImage)
  end
end
