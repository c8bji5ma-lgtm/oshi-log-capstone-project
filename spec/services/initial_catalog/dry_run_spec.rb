require "rails_helper"

RSpec.describe InitialCatalog::DryRun, type: :service do
  subject(:run) { described_class.call(path: catalog_path) }

  let(:catalog_path) { Rails.root.join("docs/issue-92-initial-catalog-candidates.yml") }

  it "previews the 17 reviewed candidates and holds the three unconfirmed sources without writing" do
    before_counts = counts

    result = run
    repeated_result = described_class.call(path: catalog_path)

    expect(result[:mode]).to eq("dry_run")
    expect(result[:writes_performed]).to be(false)
    expect(result[:catalog][:candidate_count]).to eq(20)
    expect(result[:summary]).to include(create_oshi: 17, conflict: 0, hold: 3)
    expect(result[:actions][:hold]).to match_array(%w[
      jp-osawa-hanazawa-kana
      jp-onepiece-monkey-d-luffy
      jp-spyfamily-anya-forger
    ])
    expect(result[:images]).to include(blobs_created: 0, attachments_created: 0, common_images_created: 0)
    expect(result[:database_snapshot][:before]).to eq(result[:database_snapshot][:after])
    expect(repeated_result[:actions]).to eq(result[:actions])
    expect(repeated_result[:database_snapshot][:before]).to eq(repeated_result[:database_snapshot][:after])
    expect(counts).to eq(before_counts)
  end

  it "reports an exact existing name as a conflict instead of linking or creating automatically" do
    existing = create(:oshi, :approved, name: "百田夏菜子")

    result = run
    conflict = result[:actions][:conflict].find { |item| item[:stable_id] == "jp-momoclo-momota-kanako" }

    expect(conflict).to include(reason: "existing_match")
    expect(conflict[:matches]).to contain_exactly(include(oshi_id: existing.id, status: "approved", identity: "unconfirmed"))
    expect(result[:actions][:create_oshi]).not_to include("jp-momoclo-momota-kanako")
  end

  it "reports a normalized alias match as a conflict" do
    existing = create(:oshi, :pending, name: "別の表示名")
    create(:oshi_alias, oshi: existing, alias_name: "井上和")

    result = run
    conflict = result[:actions][:conflict].find { |item| item[:stable_id] == "jp-nogizaka46-inoue-nagi-55389" }

    expect(conflict).to include(reason: "existing_match")
    expect(conflict[:matches]).to contain_exactly(include(oshi_id: existing.id, status: "pending", match_types: include("normalized")))
  end

  it "rejects duplicate stable IDs before querying candidates" do
    duplicate_catalog = YAML.safe_load(catalog_path.read, aliases: false)
    duplicate_catalog["candidates"] << duplicate_catalog.fetch("candidates").first.deep_dup

    Tempfile.create([ "initial-catalog", ".yml" ], Rails.root.join("tmp")) do |file|
      file.write(duplicate_catalog.to_yaml)
      file.flush

      expect { described_class.call(path: file.path) }
        .to raise_error(described_class::InvalidCatalog, /stable_id/)
    end
  end

  it "reports normalized name and alias collisions between catalog candidates" do
    conflicting_catalog = YAML.safe_load(catalog_path.read, aliases: false)
    conflicting_catalog.fetch("candidates")[1]["aliases"] << "百田 夏菜子"

    with_catalog(conflicting_catalog) do |path|
      result = described_class.call(path: path)
      conflicts = result[:actions][:conflict].select { |item| item[:reason] == "candidate_value_collision" }

      expect(conflicts.map { |item| item[:stable_id] })
        .to include("jp-momoclo-momota-kanako", "jp-momoclo-tamai-shiori")
    end
  end

  it "reports invalid candidate fields without attempting to create them" do
    invalid_catalog = YAML.safe_load(catalog_path.read, aliases: false)
    invalid_catalog.fetch("candidates").first["oshi_type"] = "未定義"
    invalid_catalog.fetch("candidates").first["aliases"] = "配列ではない"

    with_catalog(invalid_catalog) do |path|
      result = described_class.call(path: path)
      conflict = result[:actions][:conflict].find { |item| item[:stable_id] == "jp-momoclo-momota-kanako" }

      expect(conflict).to include(reason: "invalid_candidate")
      expect(conflict[:errors]).to include("invalid_oshi_type", "aliases_must_be_array")
      expect(result[:actions][:create_oshi]).not_to include("jp-momoclo-momota-kanako")
    end
  end

  it "rejects malformed YAML with a catalog error" do
    Tempfile.create([ "initial-catalog", ".yml" ], Rails.root.join("tmp")) do |file|
      file.write("candidates: [unterminated")
      file.flush

      expect { described_class.call(path: file.path) }
        .to raise_error(described_class::InvalidCatalog, /候補台帳を読み込めません/)
    end
  end

  it "refuses to run in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect { run }.to raise_error(described_class::InvalidCatalog, /production/)
  end

  def counts
    {
      oshis: Oshi.count,
      aliases: OshiAlias.count,
      blobs: ActiveStorage::Blob.count,
      attachments: ActiveStorage::Attachment.count,
      common_images: OshiCommonImage.count
    }
  end


  def with_catalog(catalog)
    Tempfile.create([ "initial-catalog", ".yml" ], Rails.root.join("tmp")) do |file|
      file.write(catalog.to_yaml)
      file.flush
      yield file.path
    end
  end
end
