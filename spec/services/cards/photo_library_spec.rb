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

  it "keeps the existing one-photo output and adds two- and three-photo single-oshi collages" do
    main = library_image
    default = Cards::Crop::DEFAULT
    legacy = renderer(image_attachment_ids: [ main.id.to_s ], crops: [ default ]).render
    one = renderer(collage_image_attachment_ids: [ main.id.to_s, "", "" ],
      collage_crops: [ default, default, default ]).render
    expect(one).to eq(legacy)

    attach_colour = lambda do |colour, filename|
      bytes = Vips::Image.black(20, 30, bands: 3).new_from_image(colour).copy(interpretation: :srgb)
        .write_to_buffer(".png")
      record.library_images.attach(io: StringIO.new(bytes), filename:, content_type: "image/png")
      record.reload.image_library.last
    end
    red = attach_colour.call([ 220, 20, 20 ], "red.png")
    green = attach_colour.call([ 20, 220, 20 ], "green.png")
    blue = attach_colour.call([ 20, 20, 220 ], "blue.png")
    originals = [ red, green, blue ].to_h { |image| [ image.id, image.download ] }

    two = Vips::Image.new_from_buffer(renderer(collage_image_attachment_ids: [ red.id.to_s, green.id.to_s, "" ],
      collage_crops: [ default, default, default ]).render, "")
    expect(two.getpoint(100, 200).take(3)).to eq([ 220, 20, 20 ])
    expect(two.getpoint(600, 400).take(3)).to eq([ 20, 220, 20 ])
    expect(two.getpoint(1500, 700).take(3)).to eq([ 20, 220, 20 ])

    three = Vips::Image.new_from_buffer(renderer(collage_image_attachment_ids: [ red.id.to_s, green.id.to_s, blue.id.to_s ],
      collage_crops: [ default, default, default ]).render, "")
    expect(three.getpoint(600, 400).take(3)).to eq([ 20, 220, 20 ])
    expect(three.getpoint(1100, 400).take(3)).to eq([ 20, 20, 220 ])
    expect([ red, green, blue ].to_h { |image| [ image.id, image.download ] }).to eq(originals)
  end

  it "allows the same owned image in every collage slot and rejects foreign or malformed collage sources" do
    image = library_image
    default = Cards::Crop::DEFAULT
    expect do
      renderer(collage_image_attachment_ids: [ image.id.to_s ] * 3,
        collage_crops: [ default, default, default ]).render
    end.not_to raise_error

    foreign = create(:user_oshi).tap { |item| attach_coordinates(item) }.representative_image.attachment
    expect do
      renderer(collage_image_attachment_ids: [ image.id.to_s, foreign.id.to_s, "" ],
        collage_crops: [ default, default, default ])
    end.to raise_error(ActiveRecord::RecordNotFound)
    expect { renderer(collage_image_attachment_ids: [ image.id.to_s ], collage_crops: [ default ]) }
      .to raise_error(ArgumentError)
  end
end
