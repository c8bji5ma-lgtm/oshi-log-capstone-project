require "rails_helper"
require "tmpdir"
require_relative "../../support/card_images"

RSpec.describe Cards::Photo do
  include CardImages
  let(:user) { create(:user) }
  let(:record) { create(:user_oshi, user: user) }

  around do |example|
    previous_registry = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshilog-crop-service-") do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      ActiveStorage::Blob.services = previous_registry
      ActiveStorage::Blob.service = previous_service
    end
  end

  before { create(:profile, user: user) }

  def render_photo(records = [ record ], **options)
    described_class.new(user: user, user_oshi_ids: records.map { |item| item.id.to_s },
      image_user_oshi_ids: records.map { |item| item.id.to_s }, **options).render
  end

  def picture(png, x: 48, width: 496, height: 620)
    Vips::Image.new_from_buffer(png, "").crop(x, 176, width, height)
  end

  it "preserves the legacy central pixels when crops are omitted or explicitly defaulted" do
    bytes = attach_coordinates(record)
    source = Vips::Image.new_from_buffer(bytes, "").autorot.colourspace(:srgb)
    resized = source.resize([ 496.0 / source.width, 620.0 / source.height ].max)
    expected = resized.crop((resized.width - 496) / 2, (resized.height - 620) / 2, 496, 620)
    legacy = render_photo
    explicit = render_photo(crops: [ Cards::Crop::DEFAULT ])
    expect(explicit).to eq(legacy)
    expect((picture(legacy) - expected).abs.max).to eq(0)
  end

  it "uses the newly selected library representative without changing the photo API or originals" do
    original = attach_coordinates(record)
    previous_blob = record.representative_image.blob
    first_png = render_photo
    record.library_images.attach(io: StringIO.new(coordinate_image(width: 600, height: 900)), filename: "portrait.png")
    selected = record.reload.image_library.last
    selected_bytes = selected.download
    UserOshis::Save.call(user_oshi: record, representative_image_id: selected.id.to_s)
    changed_png = render_photo
    expect(changed_png).not_to eq(first_png)
    expect(record.reload.image_count).to eq(2)
    expect(record.representative_image.blob_id).to eq(selected.blob_id)
    expect(previous_blob.download).to eq(original)
    expect(selected.download).to eq(selected_bytes)
    image = Vips::Image.new_from_buffer(changed_png, "")
    expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
  end

  it "changes the visible extent at zoom three and leaves originals and metadata unchanged" do
    bytes = attach_coordinates(record)
    blob = record.representative_image.blob
    original_metadata = blob.reload.attributes
    original_attachment = record.representative_image.attachment.attributes
    central = picture(render_photo)
    zoomed = picture(render_photo(crops: [ { x: 0.5, y: 0.5, zoom: 3 } ]))
    expect(zoomed.getpoint(10, 10)).not_to eq(central.getpoint(10, 10))
    expect(zoomed.getpoint(10, 10)[0]).to be > central.getpoint(10, 10)[0]
    expect(record.representative_image.download).to eq(bytes)
    expect(blob.reload.attributes).to eq(original_metadata)
    expect(record.representative_image.attachment.reload.attributes).to eq(original_attachment)
  end

  it "applies the crop after EXIF orientation correction" do
    bytes = attach_coordinates(record, orientation: 6)
    source = Vips::Image.new_from_buffer(bytes, "").autorot.colourspace(:srgb)
    expect([ source.width, source.height ]).to eq([ 600, 900 ])
    crop = { x: 0.4, y: 0.6, zoom: 3 }
    expected = source.resize(2.48).crop(347, 1029, 496, 620)
    actual = picture(render_photo(crops: [ crop ]))
    expect((actual - expected).abs.max).to eq(0)
    expect(record.representative_image.download).to eq(bytes)
  end

  it "renders separate crops of the same source in two unchanged photo frames" do
    attach_coordinates(record)
    second = create(:user_oshi, user: user)
    crops = [ { x: 0.25, y: 0.35, zoom: 3 }, { x: 0.75, y: 0.65, zoom: 3 } ]
    png = render_photo([ record, second ], image_user_oshi_ids: [ record.id.to_s ] * 2, crops: crops)
    image = Vips::Image.new_from_buffer(png, "")
    expect([ image.width, image.height ]).to eq([ 1600, 1000 ])
    expect(image.getpoint(580, 436)[0]).to be < image.getpoint(1020, 436)[0]
    [ 372, 812 ].each do |x|
      expect(image.getpoint(x - 1, 176).take(3)).to eq([ 255, 255, 255 ])
      expect(image.getpoint(x + 416, 176).take(3)).to eq([ 255, 255, 255 ])
    end
  end

  it "rejects a crop which would leave the source image or crop an absent image" do
    expect { render_photo(crops: [ { x: 0.5, y: 0.5, zoom: 2 } ]) }.to raise_error(Cards::Crop::Invalid)
    attach_coordinates(record)
    expect { render_photo(crops: [ { x: 0, y: 0.5, zoom: 1 } ]) }.to raise_error(Cards::Crop::Invalid)
  end

  it "renders fractional-size source boundaries without exposing a blank edge" do
    attach_coordinates(record, width: 997, height: 613)
    scale = 620.0 / 613 * 3
    crop = { x: 1 - 496 / (2.0 * 997 * scale), y: 620 / (2.0 * 613 * scale), zoom: 3 }
    image = picture(render_photo(crops: [ crop ]))
    expect([ image.width, image.height ]).to eq([ 496, 620 ])
    expect(image.getpoint(495, 0).take(3)).not_to eq([ 255, 255, 255 ])
    expect(image.getpoint(495, 619).take(3)).not_to eq([ 255, 255, 255 ])
  end
end
