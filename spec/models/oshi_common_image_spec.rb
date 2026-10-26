require "rails_helper"

RSpec.describe OshiCommonImage, type: :model do
  it "accepts a rights-confirmed image with all required metadata" do
    expect(build(:oshi_common_image)).to be_valid
  end

  %i[source_url creator_name license_name attribution_text rights_confirmed_at].each do |attribute|
    it "rejects a missing #{attribute}" do
      image = build(:oshi_common_image)
      image.public_send("#{attribute}=", nil)
      expect(image).not_to be_valid
      expect(image.errors[attribute]).to be_present
    end
  end

  %w[http https].each do |scheme|
    it "accepts the #{scheme} source URL scheme" do
      image = build(:oshi_common_image, source_url: "#{scheme}://example.com/photo")
      expect(image).to be_valid
    end
  end

  %w[ftp://example.com/photo https://example.com/with\ space not-a-url].each do |url|
    it "rejects a non-HTTP or malformed source URL: #{url}" do
      image = build(:oshi_common_image, source_url: url)
      expect(image).not_to be_valid
      expect(image.errors[:source_url]).to be_present
    end
  end

  it "accepts exactly 2048 URL characters and rejects 2049" do
    prefix = "https://example.com/"
    image = build(:oshi_common_image, source_url: prefix.ljust(2048, "a"))
    expect(image).to be_valid
    image.source_url = prefix.ljust(2049, "a")
    expect(image).not_to be_valid
    expect(image.errors[:source_url]).to be_present
  end

  %i[creator_name license_name].each do |attribute|
    it "accepts 255 characters and rejects 256 for #{attribute}" do
      image = build(:oshi_common_image, attribute => "あ" * 255)
      expect(image).to be_valid
      image.public_send("#{attribute}=", "あ" * 256)
      expect(image).not_to be_valid
      expect(image.errors[attribute]).to be_present
    end
  end

  it "requires a definite true or false active flag" do
    expect(build(:oshi_common_image, active: true)).to be_valid
    expect(build(:oshi_common_image, active: false)).to be_valid
    image = build(:oshi_common_image, active: nil)
    expect(image).not_to be_valid
    expect(image.errors[:active]).to be_present
  end

  it "requires an uploaded image" do
    image = described_class.new(
      oshi: create(:oshi, :approved), source_url: "https://example.com/photo",
      creator_name: "作成者", license_name: "許諾済み",
      attribution_text: "作成者の画像", rights_confirmed_at: Time.current,
      active: true
    )
    expect(image).not_to be_valid
    expect(image.errors[:image]).to be_present
  end

  it "rejects a non-image attachment" do
    image = build(:oshi_common_image)
    image.image.attach(io: StringIO.new("plain-text"), filename: "text.txt", content_type: "text/plain")
    expect(image).not_to be_valid
    expect(image.errors[:image]).to be_present
  end

  it "filters inactive images using the declared active scope" do
    active = create(:oshi_common_image, active: true)
    inactive = create(:oshi_common_image, active: false)
    expect(described_class.active).to include(active)
    expect(described_class.active).not_to include(inactive)
  end
end
