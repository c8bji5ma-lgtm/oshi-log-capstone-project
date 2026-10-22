require "rails_helper"

RSpec.describe InitialCatalog::Apply, type: :service do
  subject(:apply_catalog) do
    described_class.call(expected_sha256: catalog_sha256, path: catalog_path, ledger_path: ledger_path)
  end

  let(:catalog_path) { Rails.root.join("docs/issue-92-initial-catalog-candidates.yml") }
  let(:catalog_sha256) { Digest::SHA256.file(catalog_path).hexdigest }

  around do |example|
    Dir.mktmpdir("issue92-apply-spec-", Rails.root.join("tmp")) do |directory|
      @ledger_path = Pathname(directory).join("ledger.json")
      example.run
    end
  end

  let(:ledger_path) { @ledger_path }

  it "creates only the 17 reviewed Oshis and 23 aliases as approved records without images" do
    before_images = image_counts

    expect { @result = apply_catalog }
      .to change(Oshi, :count).by(17)
      .and change(OshiAlias, :count).by(23)

    expect(@result).to include(applied: true, created_oshis: 17, created_aliases: 23, verified_records: 17)
    expect(Oshi.where(status: :approved, created_by_user_id: nil).count).to eq(17)
    expect(Oshi.where(name: [ "花澤 香菜", "モンキー・D・ルフィ", "アーニャ・フォージャー" ])).to be_empty
    expect(image_counts).to eq(before_images)
    expect(JSON.parse(ledger_path.read)).to include("state" => "complete", "catalog_sha256" => catalog_sha256)
  end

  it "is a verified no-op when rerun with the same ledger" do
    first = apply_catalog
    before = [ Oshi.order(:id).pluck(:id, :name, :status, :updated_at), OshiAlias.order(:id).pluck(:id, :oshi_id, :alias_name, :updated_at) ]

    second = described_class.call(expected_sha256: catalog_sha256, path: catalog_path, ledger_path: ledger_path)

    expect(first[:applied]).to be(true)
    expect(second).to include(applied: false, created_oshis: 0, created_aliases: 0, verified_records: 17)
    expect([ Oshi.order(:id).pluck(:id, :name, :status, :updated_at), OshiAlias.order(:id).pluck(:id, :oshi_id, :alias_name, :updated_at) ])
      .to eq(before)
  end

  it "rolls back all records when an exception occurs during creation" do
    calls = 0
    allow(Oshi).to receive(:create!).and_wrap_original do |method, **attributes|
      calls += 1
      raise ActiveRecord::RecordInvalid.new(Oshi.new) if calls == 2

      method.call(**attributes)
    end

    expect { apply_catalog }.to raise_error(described_class::Refused)
    expect(Oshi.count).to eq(0)
    expect(OshiAlias.count).to eq(0)
    expect(ledger_path).not_to exist
  end

  it "refuses an existing normalized match without changing it" do
    existing = create(:oshi, :pending, name: "百田 夏菜子", affiliation: "既存値")

    expect { apply_catalog }.to raise_error(described_class::Refused, /予定件数/)
    expect(existing.reload).to have_attributes(name: "百田 夏菜子", affiliation: "既存値", status: "pending")
    expect(ledger_path).not_to exist
  end

  it "refuses to run in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect { apply_catalog }.to raise_error(described_class::Refused, /production/)
  end

  def image_counts
    [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count, OshiCommonImage.count ]
  end
end
