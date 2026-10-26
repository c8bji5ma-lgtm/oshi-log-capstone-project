require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe OshiCommonImage, type: :model do
  include ImageAttachments

  subject(:record) { build(:oshi_common_image) }

  it "is valid with all required rights metadata and an attached image" do
    expect(record).to be_valid
  end

  describe "source_url validation" do
    it "requires a value" do
      [ nil, "", " " ].each do |value|
        candidate = build(:oshi_common_image, source_url: value)
        candidate.validate

        expect(candidate.errors.details[:source_url]).to include(error: :blank)
      end
    end

    it "accepts HTTP and HTTPS URLs" do
      [ "http://example.test/image", "https://example.test/image" ].each do |value|
        expect(build(:oshi_common_image, source_url: value)).to be_valid
      end
    end

    it "rejects unsupported, incomplete, and whitespace-containing URLs" do
      [ "ftp://example.test/image", "example.test/image", "https://example.test/an image" ].each do |value|
        candidate = build(:oshi_common_image, source_url: value)
        candidate.validate

        expect(candidate.errors.details[:source_url]).to include(error: :invalid, value: value)
      end
    end

    it "accepts exactly 2048 characters" do
      prefix = "https://example.test/"
      expect(build(:oshi_common_image, source_url: prefix + "a" * (2048 - prefix.length))).to be_valid
    end

    it "rejects more than 2048 characters" do
      prefix = "https://example.test/"
      candidate = build(:oshi_common_image, source_url: prefix + "a" * (2049 - prefix.length))
      candidate.validate

      expect(candidate.errors.details[:source_url]).to include(error: :too_long, count: 2048)
    end
  end

  { creator_name: 255, license_name: 255 }.each do |attribute, maximum|
    describe "#{attribute} validation" do
      it "requires a value" do
        [ nil, "", " " ].each do |value|
          candidate = build(:oshi_common_image, attribute => value)
          candidate.validate

          expect(candidate.errors.details[attribute]).to include(error: :blank)
        end
      end

      it "accepts exactly #{maximum} characters" do
        expect(build(:oshi_common_image, attribute => "あ" * maximum)).to be_valid
      end

      it "rejects more than #{maximum} characters" do
        candidate = build(:oshi_common_image, attribute => "あ" * (maximum + 1))
        candidate.validate

        expect(candidate.errors.details[attribute]).to include(error: :too_long, count: maximum)
      end
    end
  end

  it "requires attribution_text" do
    [ nil, "", " " ].each do |value|
      candidate = build(:oshi_common_image, attribution_text: value)
      candidate.validate

      expect(candidate.errors.details[:attribution_text]).to include(error: :blank)
    end
  end

  it "requires rights_confirmed_at" do
    candidate = build(:oshi_common_image, rights_confirmed_at: nil)
    candidate.validate

    expect(candidate.errors.details[:rights_confirmed_at]).to include(error: :blank)
  end

  it "accepts both boolean active values" do
    [ true, false ].each do |value|
      expect(build(:oshi_common_image, active: value)).to be_valid
    end
  end

  it "rejects a nil active value" do
    candidate = build(:oshi_common_image, active: nil)
    candidate.validate

    expect(candidate.errors.details[:active]).to include(error: :inclusion, value: nil)
  end

  describe "image validation" do
    def record_without_image
      described_class.new(
        oshi: build(:oshi), source_url: "https://example.test/source", creator_name: "権利者",
        license_name: "利用許諾済み", attribution_text: "画像提供：権利者",
        rights_confirmed_at: Time.current, active: true
      )
    end

    it "requires an attachment" do
      candidate = record_without_image
      candidate.validate

      expect(candidate.errors[:image]).to include("を選択してください")
    end

    %w[image.jpg image.png image.webp].each do |filename|
      it "accepts a valid #{filename} fixture" do
        candidate = record_without_image
        candidate.image.attach(image_upload(filename))

        expect(candidate).to be_valid
      end
    end

    it "rejects a disallowed MIME type" do
      candidate = record_without_image
      candidate.image.attach(image_upload("invalid.txt"))

      expect(candidate).not_to be_valid
      expect(candidate.errors[:image]).to include("はJPEG・PNG・WebP形式の画像を指定してください")
    end

    it "rejects corrupt image bytes with an allowed MIME type" do
      candidate = record_without_image
      bytes = ImageAttachmentInspector::PNG_SIGNATURE + "broken"
      candidate.image.attach(image_upload_data(bytes, filename: "broken.png"))

      expect(candidate).not_to be_valid
      expect(candidate.errors[:image]).to include("を画像として読み取れません")
    end

    it "accepts exactly 10 MiB" do
      candidate = record_without_image
      candidate.image.attach(image_upload(size: 10 * 1024 * 1024))

      expect(candidate).to be_valid
    end

    it "rejects more than 10 MiB" do
      candidate = record_without_image
      candidate.image.attach(image_upload(size: 10 * 1024 * 1024 + 1))

      expect(candidate).not_to be_valid
      expect(candidate.errors[:image]).to include("は1画像あたり10 MiB以下にしてください")
    end

    it "accepts the maximum edge boundary" do
      candidate = record_without_image
      candidate.image.attach(image_upload_data(flat_png(2560, 100)))

      expect(candidate).to be_valid
    end

    it "rejects an image over the maximum edge boundary" do
      candidate = record_without_image
      candidate.image.attach(image_upload_data(flat_png(2561, 100)))

      expect(candidate).not_to be_valid
      expect(candidate.errors[:image]).to include("は最大辺2560px・総画素数500万以下にしてください")
    end

    it "accepts the total pixel boundary" do
      candidate = record_without_image
      candidate.image.attach(image_upload_data(flat_png(2500, 2000)))

      expect(candidate).to be_valid
    end

    it "rejects an image over the total pixel boundary" do
      candidate = record_without_image
      candidate.image.attach(image_upload_data(flat_png(2500, 2001)))

      expect(candidate).not_to be_valid
      expect(candidate.errors[:image]).to include("は最大辺2560px・総画素数500万以下にしてください")
    end
  end
  it "filters inactive images using the declared active scope" do
    active = create(:oshi_common_image, active: true)
    inactive = create(:oshi_common_image, active: false)
    expect(described_class.active).to include(active)
    expect(described_class.active).not_to include(inactive)
  end
end
