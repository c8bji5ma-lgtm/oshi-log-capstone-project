require "rails_helper"
require_relative "../../support/image_attachments"

RSpec.describe Oshis::Delete do
  include ImageAttachments
  include ActiveSupport::Testing::TimeHelpers

  def delete(record, confirmation: described_class.confirmation(record))
    described_class.call(id: record.id, confirmation: confirmation)
  end

  %i[pending approved rejected].each do |status|
    it "deletes an unused #{status} master and keeps its creator" do
      creator = create(:user, :admin)
      record = create(:oshi, status, created_by_user: creator)
      expect { delete(record) }.to change(Oshi, :count).by(-1)
      expect(User.exists?(creator.id)).to be(true)
    end
  end

  [ nil, "0", "-1", "1abc", "9223372036854775808" ].each do |id|
    it "rejects malformed id #{id.inspect}" do
      record = create(:oshi)
      expect { described_class.call(id: id, confirmation: described_class.confirmation(record)) }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect(record.reload).to be_persisted
    end
  end

  %i[user_oshis activity_oshis subscription_oshis oshi_common_images oshi_aliases].each do |reference|
    it "refuses #{reference}, retaining records and image bytes" do
      record = create(:oshi)
      related = case reference
      when :user_oshis
        create(:user_oshi, oshi: record).tap { |item| item.representative_image.attach(image_upload) }
      when :activity_oshis
        create(:activity, :without_oshis, oshis: [ record ]).tap { |item| item.images.attach(image_upload) }
      when :subscription_oshis
        create(:subscription, oshis: [ record ])
      when :oshi_common_images
        create(:oshi_common_image, oshi: record, active: false)
      when :oshi_aliases
        create(:oshi_alias, oshi: record)
      end
      models = [ Oshi, UserOshi, Activity, ActivityOshi, Subscription, SubscriptionOshi, OshiAlias,
        OshiCommonImage, ActiveStorage::Attachment, ActiveStorage::Blob ]
      counts = models.map(&:count)
      bytes = ActiveStorage::Blob.order(:id).map(&:download)
      expect { delete(record) }.to raise_error(described_class::InUse) { |error| expect(error.references).to include(reference) }
      expect(models.map(&:count)).to eq(counts)
      expect(ActiveStorage::Blob.order(:id).map(&:download)).to eq(bytes)
      expect(related.reload).to be_persisted
      expect(record.reload).to be_persisted
    end
  end

  it "rejects missing, malformed, tampered and other-master confirmation tokens" do
    record, other = create_list(:oshi, 2)
    [ nil, [], "invalid", described_class.confirmation(other), described_class.confirmation(record) + "x" ].each do |token|
      expect { delete(record, confirmation: token) }.to raise_error(described_class::InvalidConfirmation)
    end
    expect(record.reload).to be_persisted
    expect(other.reload).to be_persisted
  end

  it "requires confirmation again after the displayed master changes" do
    record = create(:oshi)
    token = described_class.confirmation(record)
    record.update!(name: "変更後の名称")
    expect { delete(record, confirmation: token) }.to raise_error(described_class::InvalidConfirmation)
    expect(record.reload.name).to eq("変更後の名称")
  end

  it "expires confirmation after fifteen minutes" do
    record = create(:oshi)
    token = described_class.confirmation(record)
    travel 16.minutes do
      expect { delete(record, confirmation: token) }.to raise_error(described_class::InvalidConfirmation)
    end
    expect(record.reload).to be_persisted
  end

  it "rechecks use added after confirmation" do
    record = create(:oshi)
    token = described_class.confirmation(record)
    registration = create(:user_oshi, oshi: record)
    expect { delete(record, confirmation: token) }.to raise_error(described_class::InUse)
    expect(registration.reload.oshi_id).to eq(record.id)
  end

  it "rolls back a failure raised after DELETE, including inside an outer transaction" do
    record = create(:oshi)
    allow_any_instance_of(Oshi).to receive(:destroy!).and_wrap_original do |method|
      method.call
      raise IOError, "artificial deletion failure"
    end
    Oshi.transaction do
      expect { delete(record) }.to raise_error(IOError, "artificial deletion failure")
      expect(Oshi.exists?(record.id)).to be(true)
    end
  end
end
