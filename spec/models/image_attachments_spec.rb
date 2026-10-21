require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Image attachments", type: :model do
  include ImageAttachments

  { profile: :profile_image, user_oshi: :representative_image, activity: :images }.each do |factory, name|
    context factory.to_s do
      let(:record) { build(factory) }

      it "allows no image" do
        expect(record).to be_valid
      end

      it "defines the specified attachment cardinality" do
        macro = factory == :activity ? :has_many_attached : :has_one_attached
        expect(record.class.reflect_on_attachment(name).macro).to eq(macro)
      end

      %w[image.jpg image.png image.webp].each do |filename|
        it "validates pending #{filename} and preserves original bytes after saving" do
          record.public_send(name).attach(image_upload(filename))
          expect(record).to be_valid
          record.save!
          attachment = record.reload.public_send(name)
          expect(record).to be_valid
          attachment = attachment.first if factory == :activity
          expect(attachment.download).to eq(File.binread(Rails.root.join("spec/fixtures/files", filename)))
        end
      end

      it "rejects a pending non-image without persisting blobs or attachments" do
        counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
        record.public_send(name).attach(image_upload("invalid.txt"))
        expect(record).not_to be_valid
        expect(record.errors[name]).not_to be_empty
        expect(record.save).to be(false)
        expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      end

      it "rejects a disallowed MIME type even when the filename ends in png" do
        upload = { io: StringIO.new("GIF89a" + "\0" * 20), filename: "fake.png" }
        record.public_send(name).attach(upload)
        expect(record).not_to be_valid
      end

      %w[image/gif image/heic image/heif image/svg+xml application/pdf text/plain].each do |content_type|
        it "rejects blob content_type #{content_type}" do
          upload = image_upload.merge(content_type: content_type, identify: false)
          record.public_send(name).attach(upload)
          expect(record).not_to be_valid
          expect(record.errors[name]).not_to be_empty
        end
      end

      it "accepts exactly 10 MiB" do
        record.public_send(name).attach(image_upload(size: 10 * 1024 * 1024))
        expect(record).to be_valid
      end

      it "rejects 10 MiB plus one byte without persisting blobs or attachments" do
        counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
        record.public_send(name).attach(image_upload(size: 10 * 1024 * 1024 + 1))
        expect(record.save).to be(false)
        expect(record.errors[name]).not_to be_empty
        expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      end

      unless factory == :activity
        it "preserves an existing image when replacement validation fails" do
          record.public_send(name).attach(image_upload)
          record.save!
          original_id = record.public_send(name).blob.id
          counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
          expect(record.public_send(name).attach(image_upload("invalid.txt"))).to be_nil
          expect(record.errors[name]).not_to be_empty
          expect(record.reload.public_send(name).blob.id).to eq(original_id)
          expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
        end
      end
    end
  end

  it "rejects a newly attached image over the dimension limit" do
    record = build(:profile)
    upload = image_upload_data(flat_png(2561, 100))
    record.profile_image.attach(upload)

    expect(record).not_to be_valid
    expect(record.errors[:profile_image]).to include("は最大辺2560px・総画素数500万以下にしてください")
  end

  it "does not reapply new dimension limits when an existing attachment is unchanged" do
    record = create(:profile)
    bytes = flat_png(2561, 100)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes), filename: "legacy.png", content_type: "image/png", identify: false
    )
    ActiveStorage::Attachment.create!(name: "profile_image", record: record, blob: blob)
    original = blob.reload.attributes

    expect { record.update!(introduction: "既存画像を変更しない編集") }.not_to change {
      [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    }
    expect(record.reload.profile_image.blob.attributes).to eq(original)
    expect(record.profile_image.download).to eq(bytes)
  end

  it "keeps the common Oshi master free of attachments" do
    expect(Oshi.reflect_on_all_attachments).to be_empty
  end

  it "saves multiple Activity originals" do
    activity = build(:activity)
    activity.images.attach([ image_upload("image.jpg"), image_upload("image.webp") ])
    activity.save!
    expect(activity.reload.images.map(&:download)).to eq(
      %w[image.jpg image.webp].map { |filename| File.binread(Rails.root.join("spec/fixtures/files", filename)) }
    )
  end

  [ "invalid.txt", :oversized ].each do |invalid|
    it "rejects an Activity if one of several pending images is #{invalid}" do
      activity = build(:activity)
      upload = invalid == :oversized ? image_upload(size: 10 * 1024 * 1024 + 1) : image_upload(invalid)
      activity.images.attach([ image_upload, upload ])
      expect(activity).not_to be_valid
    end
  end
end
