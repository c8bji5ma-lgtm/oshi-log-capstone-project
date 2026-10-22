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

  it "removes the uploaded file and blob when persistence fails after the physical upload" do
    existing = create(:oshi_common_image, oshi: oshi, registered_by_user: admin)
    existing_bytes = existing.image.download
    uploaded_blob = nil
    allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |original, **arguments|
      uploaded_blob = original.call(**arguments)
    end
    allow_any_instance_of(OshiCommonImage).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, "injected DB failure")

    expect do
      described_class.call(oshi: oshi, administrator: admin, attributes: attributes, file: upload)
    end.to raise_error(ActiveRecord::StatementInvalid, /injected DB failure/)

    expect(uploaded_blob).to be_present
    expect(ActiveStorage::Blob.service.exist?(uploaded_blob.key)).to be(false)
    expect(ActiveStorage::Blob.where(key: uploaded_blob.key)).not_to exist
    expect(ActiveStorage::Attachment.where(blob_id: uploaded_blob.id)).not_to exist
    expect(existing.reload.image.download).to eq(existing_bytes)
    expect(existing).to have_attributes(attribution_text: "画像提供：権利者")
  end

  describe "concurrent limit enforcement" do
    self.use_transactional_tests = false

    around do |example|
      models = [ ActiveStorage::Attachment, OshiCommonImage, Oshi, User, ActiveStorage::Blob ]
      baseline_ids = models.to_h { |model| [ model, model.pluck(:id) ] }
      example.run
    ensure
      models.each { |model| model.where.not(id: baseline_ids.fetch(model)).delete_all }
    end

    it "serializes two real connections and persists only the tenth record" do
      9.times do |index|
        create(:oshi_common_image, oshi: oshi, registered_by_user: admin,
          source_url: "https://example.test/existing/#{index}")
      end
      ready = Queue.new
      start = Queue.new
      results = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            result = described_class.call(oshi: Oshi.find(oshi.id), administrator: User.find(admin.id),
              attributes: attributes.merge(source_url: "https://example.test/concurrent/#{index}"), file: upload)
            results << [ :created, result.id ]
          rescue StandardError => error
            results << [ :error, error ]
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
      outcomes = 2.times.map { results.pop }

      expect(outcomes.count { |status, _| status == :created }).to eq(1)
      expect(outcomes.count { |status, error| status == :error && error.is_a?(ActiveRecord::RecordInvalid) }).to eq(1)
      expect(oshi.oshi_common_images.reload.count).to eq(10)
    end
  end
end
