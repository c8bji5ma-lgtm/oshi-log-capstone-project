require "rails_helper"
require_relative "../../support/image_attachments"
require_relative "../../support/user_oshi_images"

RSpec.describe UserOshis::Save do
  include ImageAttachments
  include UserOshiImages

  let(:record) { create(:user_oshi) }

  def save_images(files, target = record, **options)
    described_class.call(user_oshi: target, new_images: files, **options)
  end

  def stored_counts
    [ UserOshi.count, Oshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
  end

  it "creates an empty library and permits no representative" do
    save_images([], build(:user_oshi))
    expect(UserOshi.last.image_count).to eq(0)
  end

  it "registers multiple originals and selects the first without counting it twice" do
    target = build(:user_oshi)
    save_images(%w[image.jpg image.webp image.png].map { |file| library_upload(file) }, target)
    expect(target.reload.image_count).to eq(3)
    expect(target.remaining_image_count).to eq(27)
    expect(target.representative_image.blob).to eq(target.image_library.first.blob)
    expect(target.image_library.map(&:download)).to eq(%w[image.jpg image.webp image.png].map do |file|
      File.binread(Rails.root.join("spec/fixtures/files", file))
    end)
  end

  it "retains images appended through another instance even when associations are stale" do
    record.library_images.attach(image_upload)
    record.image_library
    save_images([ library_upload("image.jpg") ], UserOshi.find(record.id))
    save_images([ library_upload("image.webp") ])
    expect(record.reload.image_library.map { |image| image.filename.to_s }).to eq(%w[image.png image.jpg image.webp])
  end

  [ false, true ].each do |legacy|
    it "accepts exactly 30 and refuses image 31 with legacy representative=#{legacy}" do
      record.representative_image.attach(image_upload) if legacy
      save_images(Array.new(legacy ? 29 : 30) { library_upload })
      expect(record.reload.image_count).to eq(30)
      expect(record.remaining_image_count).to eq(0)
      counts = stored_counts
      ids = record.image_library.map(&:id)
      expect { save_images([ library_upload ]) }.to raise_error(ActiveRecord::RecordInvalid, /30/)
      expect(stored_counts).to eq(counts)
      expect(record.reload.image_library.map(&:id)).to eq(ids)
    end
  end

  [ "invalid.txt", :oversized ].each do |invalid|
    it "rejects a mixed batch containing #{invalid} and preserves every saved field" do
      record.representative_image.attach(image_upload)
      original = record.attributes
      image_id = record.representative_image.attachment.id
      counts = stored_counts
      bad = invalid == :oversized ? library_upload(size: 10.megabytes + 1) : library_upload(invalid)
      expect { save_images([ library_upload, bad ], record, attributes: { started_period: "2020" }) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(stored_counts).to eq(counts)
      expect(record.reload.attributes).to eq(original)
      expect(record.representative_image.attachment.id).to eq(image_id)
      expect(record.library_images).not_to be_attached
    end
  end

  it "accepts an image of exactly 10 MiB" do
    save_images([ library_upload(size: 10.megabytes) ])
    expect(record.reload.library_images.first.byte_size).to eq(10.megabytes)
  end

  it "rejects 31 uploads together without saving any original" do
    target = build(:user_oshi, user: create(:user), oshi: create(:oshi))
    counts = stored_counts
    expect { save_images(Array.new(31) { library_upload }, target) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(stored_counts).to eq(counts)
  end

  it "rolls back database records and cleans files after the second disk upload fails" do
    record.representative_image.attach(image_upload)
    before = stored_counts
    original_id = record.representative_image.blob_id
    keys = []
    disk = ActiveStorage::Blob.service
    allow(disk).to receive(:upload).and_wrap_original do |method, key, *args, **kwargs|
      keys << key
      method.call(key, *args, **kwargs)
      raise IOError, "disk unavailable" if keys.size == 2
    end
    expect { save_images([ library_upload, library_upload ]) }.to raise_error(ActiveRecord::RecordInvalid, /保存できません/)
    expect(keys.size).to eq(2)
    expect(keys.map { |key| disk.exist?(key) }).to eq([ false, false ])
    expect(stored_counts).to eq(before)
    expect(record.reload.representative_image.blob_id).to eq(original_id)
    expect(record.representative_image.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
  end

  it "cleans newly uploaded files if a later database save fails" do
    record
    before = stored_counts
    keys = []
    allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |method, key, *args, **kwargs|
      keys << key
      method.call(key, *args, **kwargs)
    end
    allow(record).to receive(:save).and_wrap_original do |method|
      method.call
      raise ActiveRecord::RecordNotSaved
    end
    expect { save_images([ library_upload ]) }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(stored_counts).to eq(before)
    expect(keys).not_to be_empty
    expect(keys.all? { |key| !ActiveStorage::Blob.service.exist?(key) }).to be(true)
  end

  it "retains the legacy original and stable ordering when changing representatives" do
    record.representative_image.attach(image_upload("image.jpg"))
    old_blob = record.representative_image.blob
    save_images([ library_upload("image.webp") ])
    before = record.reload.image_library.map(&:blob_id)
    selected = record.image_library.last
    described_class.call(user_oshi: record, representative_image_id: selected.id.to_s)
    expect(record.reload.representative_image.blob_id).to eq(selected.blob_id)
    expect(record.image_library.map(&:blob_id)).to eq(before)
    expect(record.library_images.blobs).to include(old_blob)
    expect(old_blob.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.jpg")))
  end

  it "keeps library images and originals intact when the existing admin merger refuses their attachments" do
    save_images([ library_upload, library_upload("image.webp") ])
    before = record.reload.image_library.map { |image| [ image.id, image.blob_id, image.download ] }
    target = create(:oshi)
    expect { Oshis::Merge.call(source_id: record.oshi_id, target_id: target.id) }
      .to raise_error(Oshis::Merge::Conflict)
    expect(record.reload.image_library.map { |image| [ image.id, image.blob_id, image.download ] }).to eq(before)
  end

  it "does not create redundant library or representative references on repeated selection" do
    save_images([ library_upload ])
    id = record.reload.image_library.first.id.to_s
    expect do
      2.times { described_class.call(user_oshi: record, representative_image_id: id) }
    end.not_to change(ActiveStorage::Attachment, :count)
    expect(record.reload.image_count).to eq(1)
  end

  it "refuses implicit deletion of a representative and explicitly clears it without choosing another" do
    save_images([ library_upload, library_upload("image.webp") ])
    id = record.reload.image_library.first.id.to_s
    counts = stored_counts
    expect { described_class.call(user_oshi: record, remove_image_id: id) }
      .to raise_error(ActiveRecord::RecordInvalid, /解除/)
    expect(stored_counts).to eq(counts)
    described_class.call(user_oshi: record.reload, remove_image_id: id, clear_representative: true)
    expect(record.reload.representative_image).not_to be_attached
    expect(record.image_count).to eq(1)
    expect(record.image_library.first.filename.to_s).to eq("image.webp")
  end

  it "can explicitly delete a legacy representative without library migration" do
    record.representative_image.attach(image_upload)
    described_class.call(user_oshi: record, remove_image_id: record.representative_image.attachment.id.to_s, clear_representative: true)
    expect(record.reload.image_count).to eq(0)
    expect(record.representative_image).not_to be_attached
  end

  it "deletes only the specified non-representative image" do
    save_images([ library_upload, library_upload("image.webp"), library_upload("image.jpg") ])
    ids = record.reload.image_library.map(&:id)
    described_class.call(user_oshi: record, remove_image_id: ids[1].to_s)
    expect(record.reload.image_library.map(&:id)).to eq([ ids[0], ids[2] ])
    expect(record.image_count).to eq(2)
  end

  [ :representative_image_id, :remove_image_id ].each do |operation|
    it "refuses foreign, other-oshi, nonexistent and malformed IDs for #{operation}" do
      save_images([ library_upload ])
      other = create(:user_oshi, user: record.user)
      foreign = create(:user_oshi)
      [ other, foreign ].each { |target| save_images([ library_upload ], target) }
      ids = [ other.image_library.first.id.to_s, foreign.image_library.first.id.to_s, "0", "1abc", "invalid", [ "1" ] ]
      counts = stored_counts
      original = record.representative_image.blob_id
      ids.each do |id|
        expect { described_class.call(user_oshi: record.reload, **{ operation => id }) }.to raise_error(ActiveRecord::RecordNotFound)
      end
      expect(stored_counts).to eq(counts)
      expect(record.reload.representative_image.blob_id).to eq(original)
    end
  end
end
