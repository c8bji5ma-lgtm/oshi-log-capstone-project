require "rails_helper"
require "tmpdir"
require_relative "../../support/image_attachments"

RSpec.describe OshiCommonImages::Create do
  include ImageAttachments

  let(:oshi) { create(:oshi, :approved) }
  let(:admin) { create(:user, :admin) }
  let(:attributes) do
    { source_url: "https://example.test/source", creator_name: "作者", license_name: "許諾済み",
      attribution_text: "画像：作者", rights_confirmed_at: Time.current, active: true }
  end

  def upload(filename = "image.png", content_type = "image/png")
    path = Rails.root.join("spec/fixtures/files", filename)
    tempfile = Tempfile.new([ "common-image", File.extname(filename) ])
    tempfile.binmode
    tempfile.write(File.binread(path))
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(
      tempfile: tempfile, filename: filename, type: content_type
    )
  end

  around do |example|
    previous_registry = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshi-common-images-") do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    end
  ensure
    ActiveStorage::Blob.services = previous_registry
    ActiveStorage::Blob.service = previous_service
  end

  it "stores one inspected image and its rights metadata" do
    record = described_class.call(oshi: oshi, administrator: admin, attributes: attributes, file: upload)
    expect(record).to be_persisted
    expect(record).to have_attributes(oshi: oshi, registered_by_user: admin, attribution_text: "画像：作者")
    expect(record.image).to be_attached
    expect(record.image.download).not_to be_empty
  end

  it "rejects an eleventh record without changing existing images" do
    10.times do |index|
      record = create(:oshi_common_image, oshi: oshi, registered_by_user: admin,
        source_url: "https://example.test/existing/#{index}")
    end
    before = oshi.oshi_common_images.order(:id).pluck(:id)
    expect do
      described_class.call(oshi: oshi, administrator: admin, attributes: attributes, file: upload)
    end.to raise_error(ActiveRecord::RecordInvalid, /最大10枚/)
    expect(oshi.oshi_common_images.order(:id).pluck(:id)).to eq(before)
  end

  it "does not persist metadata or blobs for a broken image" do
    broken = upload("invalid.txt", "image/png")
    expect do
      described_class.call(oshi: oshi, administrator: admin, attributes: attributes, file: broken)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(OshiCommonImage.count).to eq(0)
    expect(ActiveStorage::Blob.count).to eq(0)
  end
end
