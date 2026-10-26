require "rails_helper"
require "tmpdir"
require "fileutils"
require_relative "../support/image_attachments"
require_relative "../../db/seeds/development"

RSpec.describe DevelopmentSeeds::Dataset, type: :model do
  include ImageAttachments

  # Actual commits are necessary to test file uploads and the phase boundary.
  # Cleanup is restricted to rows created by this example and its private disk.
  self.use_transactional_tests = false

  let(:reference_date) { Date.new(2026, 10, 6) }
  let(:dataset) { described_class.new(reference_date: reference_date) }
  let(:models) do
    [ User, Profile, Oshi, OshiAlias, UserOshi, Activity, ActivityOshi,
      Emotion, ActivityEmotion, Subscription, SubscriptionOshi, OshiCommonImage,
      ActiveStorage::Blob, ActiveStorage::Attachment, ActiveStorage::VariantRecord ]
  end
  let(:emails) { %w[demo multi light empty admin].map { |name| "#{name}@example.com" } }

  around do |example|
    raise "Seed specs require the test environment" unless Rails.env.test?

    baseline_ids = models.to_h { |model| [ model, model.pluck(:id) ] }
    original_services = ActiveStorage::Blob.services
    original_blob_service = ActiveStorage::Blob.service
    root = Rails.root.join("tmp/storage")
    FileUtils.mkdir_p(root)
    Dir.mktmpdir("seed-spec-", root) do |directory|
      service = ActiveStorage::Service::DiskService.new(root: directory)
      service.name = "test"
      ActiveStorage::Blob.services = { "test" => service, test: service }
      ActiveStorage::Blob.service = service
      begin
        example.run
      ensure
        # Delete only test rows absent from the pre-example snapshot, children
        # first. No callbacks/jobs may operate on storage after the test ends.
        [ ActiveStorage::VariantRecord, ActiveStorage::Attachment, OshiCommonImage, ActivityEmotion, ActivityOshi,
          SubscriptionOshi, OshiAlias, UserOshi, Activity, Subscription,
          Profile, Oshi, User, Emotion, ActiveStorage::Blob ].each do |model|
          model.where.not(id: baseline_ids.fetch(model)).delete_all
        end
        ActiveStorage::Blob.services = original_services
        ActiveStorage::Blob.service = original_blob_service
      end
    end
  end

  def counts
    models.map(&:count)
  end

  def table_counts
    connection = ActiveRecord::Base.connection
    connection.tables.sort.to_h do |table|
      [ table, connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i ]
    end
  end

  def demo
    User.find_by!(email: "demo@example.com")
  end

  def seeded_activity
    demo.activities.find_by!(title: "【デモ】合同ライブ")
  end

  def expect_seed_images_downloadable
    ActiveStorage::Attachment.includes(:blob).each do |attachment|
      filename = attachment.blob.filename.to_s
      next unless filename.start_with?("seed-")

      expect(attachment.download).to eq(File.binread(Rails.root.join("db/seeds/assets", filename)))
    end
  end

  it "does not automatically execute either entrypoint under the non-development guard" do
    # The global Emotion master is intentionally populated by db/seeds.rb in every environment.
    business_models = models - [ Emotion ]
    before = business_models.map(&:count)
    # Stub only the guard predicate; Rails.env and the test DB connection stay intact.
    allow(Rails.env).to receive(:development?).and_return(false)
    expect(described_class).not_to receive(:new)
    expect do
      load Rails.root.join("db/seeds.rb")
      load Rails.root.join("db/seeds/development.rb")
    end.not_to output.to_stdout
    expect(business_models.map(&:count)).to eq(before)
    expect(Rails.env.test?).to be(true)
  end

  it "keeps global and reserved dataset counts stable, with original image bytes on both runs" do
    schema_tables = Rails.root.join("db/schema.rb").read.scan(/^\s*create_table "([^"]+)"/).flatten
    expect(models.map(&:table_name)).to match_array(schema_tables)
    before_tables = table_counts
    before = counts
    missing_emotion_names = Emotion::DEFAULT_NAMES.count { |name| !Emotion.exists?(name: name) }
    dataset.call
    expected = [ 5, 5, 6, 5, 8, 42, 56, missing_emotion_names, 5, 12, 12, 5, 12, 12, 0 ]
    expect(counts.zip(before).map { |after, original| after - original }).to eq(expected)
    first_tables = table_counts
    models.reject { |model| model == ActiveStorage::VariantRecord }.each do |model|
      expect(first_tables.fetch(model.table_name)).to be >= 5
    end
    ids = models.map { |model| model.order(:id).pluck(:id) }
    expect_seed_images_downloadable

    dataset.call
    expect(models.map { |model| model.order(:id).pluck(:id) }).to eq(ids)
    second_tables = table_counts
    expect(second_tables).to eq(first_tables)
    directory = Rails.root.join("tmp/issue110")
    FileUtils.mkdir_p(directory)
    File.write(directory.join("seed-counts.json"), JSON.pretty_generate({
      environment: Rails.env, database: ActiveRecord::Base.connection_db_config.database,
      reference_date: reference_date.iso8601, schema_tables: schema_tables.sort,
      before: before_tables, after_first: first_tables, after_second: second_tables
    }))
    expect(User.where(email: emails).count).to eq(5)
    expect(Profile.where(user: User.where(email: emails)).count).to eq(5)
    expect(Oshi.where(created_by_user: User.where(email: emails)).count).to eq(6)
    expect(OshiAlias.where(oshi: Oshi.where(created_by_user: User.where(email: emails))).count).to eq(5)
    expect(UserOshi.where(user: User.where(email: emails)).count).to eq(8)
    expect(ActivityEmotion.joins(:activity).where(activities: { user_id: demo.id }).count).to eq(5)
    common_images = OshiCommonImage.where(registered_by_user: User.find_by!(email: "admin@example.com"))
    expect(common_images.count).to eq(5)
    expect(common_images.map(&:creator_name).uniq).to match_array([ "Yvette de Wit", "Matt Botsford", "Christie Kim" ])
    expect(common_images.all? { |image| image.image.attached? && image.valid? }).to be(true)
    source_rows = Rails.root.join("db/seeds/assets/SOURCES.md").read.lines.filter_map do |line|
      next unless line.start_with?("| seed-")

      filename, _service, url, author, _license = line.split("|").map(&:strip).drop(1)
      [ filename, { source_url: url, creator_name: author } ]
    end.to_h
    common_images.each do |image|
      expect(image).to have_attributes(**source_rows.fetch(image.image.filename.to_s), license_name: "Unsplash License")
      expect(image.rights_confirmed_at.to_date).to eq(reference_date)
      expect(image.attribution_text).to eq("写真：#{image.creator_name} / Unsplash")
    end
    expect(Activity.where(user: User.where(email: emails)).count).to eq(42)
    expect(ActivityOshi.where(activity: Activity.where(user: User.where(email: emails))).count).to eq(56)
    expect(Subscription.where(user: User.where(email: emails)).count).to eq(12)
    expect(SubscriptionOshi.where(subscription: Subscription.where(user: User.where(email: emails))).count).to eq(12)
    expect(demo.activities.find_by!(title: "【デモ】周年ライブ").images.map { |image| image.filename.to_s })
      .to match_array(%w[seed-concert.jpg seed-microphone.jpg seed-flowers.jpg])
    expect_seed_images_downloadable

    summary = OshiData::Summary.new(user: demo, date: reference_date)
    expect([ summary.activity_count, summary.activity_amount, summary.activity_change ]).to eq([ 16, 117300, 8 ])
    expect([ summary.monthly_fixed_cost, summary.yearly_fixed_cost ]).to eq([ 4080, 6600 ])
    expect(summary.highlight).to eq("最近3か月は「ライブ・イベント」の割合が増えています。")
  end

  it "reconciles an already existing reserved user and restores managed attributes and links" do
    reserved = create(:user, :admin, email: "demo@example.com", password: "changed-password")
    create(:profile, user: reserved, display_name: "手入力", introduction: "変更前")
    dataset.call
    expect(demo.id).to eq(reserved.id)
    expect(demo.admin).to be(false)
    expect(demo.valid_password?("password123")).to be(true)
    expect(demo.profile).to have_attributes(display_name: "YUKI", introduction: "推し活の記録を楽しんでいます。")

    lumina = Oshi.find_by!(name: "LUMINA", oshi_type: "アイドル", created_by_user: demo)
    lumina.update!(affiliation: "変更済み", status: :rejected)
    registration = demo.user_oshis.find_by!(oshi: lumina)
    registration.update!(started_period: "2000", ended_period: "2001/01")
    replacement = Oshi.find_by!(name: "NOVA")
    record = seeded_activity
    Activities::Save.call(activity: record, attributes: { amount: 1, occurred_on: Date.new(2000, 1, 1), memo: "変更済み" }, oshi_ids: [ replacement.id ])
    subscription = demo.subscriptions.find_by!(name: "【デモ】推し活クラウド")
    Subscriptions::Save.call(subscription: subscription, attributes: { amount: 1, billing_cycle: "yearly" }, oshi_ids: [ replacement.id ])
    demo.update!(admin: true, password: "changed-again")
    demo.profile.update!(display_name: "変更済み", introduction: nil)

    dataset.call
    expect(demo).to have_attributes(admin: false)
    expect(demo.valid_password?("password123")).to be(true)
    expect(demo.profile).to have_attributes(display_name: "YUKI", introduction: "推し活の記録を楽しんでいます。")
    expect(lumina.reload).to have_attributes(affiliation: "LUMINA PROJECT", status: "approved")
    expect(registration.reload).to have_attributes(started_period: "2024/10", ended_period: nil)
    expect(record.reload).to have_attributes(amount: 10000, occurred_on: Date.new(2026, 10, 5), memo: "初めての遠征。")
    expect(record.oshis.pluck(:name)).to match_array(%w[LUMINA ASTER])
    expect(subscription.reload).to have_attributes(amount: 500, billing_cycle: "monthly")
    expect(subscription.oshis).to be_empty
  end

  it "retains nonreserved users, their records and same-name unrelated oshis" do
    user = create(:user, :admin, email: "manual-user@example.net")
    profile = create(:profile, user: user, display_name: "MANUAL")
    unrelated = create(:oshi, :pending, name: "LUMINA", oshi_type: "アイドル", created_by_user: user)
    registration = create(:user_oshi, user: user, oshi: unrelated)
    activity = create(:activity, user: user, title: "【デモ】合同ライブ", activity_oshis: [ ActivityOshi.new(oshi: unrelated) ], oshis_count: 0)
    subscription = create(:subscription, user: user, name: "【デモ】推し活クラウド")
    link = create(:subscription_oshi, subscription: subscription, oshi: unrelated)
    common_image = create(:oshi_common_image, oshi: unrelated, registered_by_user: user)
    emotion = Emotion.create!(name: "手入力の感情", position: 99)
    emotion_link = ActivityEmotion.create!(activity: activity, emotion: emotion)
    profile.profile_image.attach(image_upload)
    activity.images.attach(image_upload("image.jpg"))
    records = [ user, profile, unrelated, registration, activity, subscription, link, common_image, emotion, emotion_link,
      *activity.activity_oshis,
      *ActiveStorage::Blob.all, *ActiveStorage::Attachment.all ]
    attributes = records.map(&:attributes)
    dataset.call
    # Reserved users can also have records whose keys are not in the dataset.
    other_type = create(:oshi, name: "LUMINA", oshi_type: "その他", created_by_user: demo)
    manual_registration = create(:user_oshi, user: demo, oshi: other_type, started_period: "2000")
    manual_activity = create(:activity, user: demo, title: "手入力の活動")
    manual_subscription = create(:subscription, user: demo, name: "手入力の契約")
    additional = [ other_type, manual_registration, manual_activity, manual_subscription, *manual_activity.activity_oshis ]
    additional_attributes = additional.map(&:attributes)
    dataset.call
    expect(records.map { |record| record.reload.attributes }).to eq(attributes)
    expect(additional.map { |record| record.reload.attributes }).to eq(additional_attributes)
    expect(profile.reload.profile_image.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
    expect(activity.reload.images.sole.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.jpg")))
  end

  it "repairs missing, changed and duplicate seed images while retaining manual one/many images" do
    dataset.call
    profile = demo.profile
    profile.profile_image.purge
    profile.profile_image.attach(image_upload("image.jpg").merge(filename: "seed-flowers.jpg"))
    original_profile_blob_id = profile.profile_image.blob.id
    representative = demo.user_oshis.find_by!(oshi: Oshi.find_by!(name: "LUMINA"))
    representative.representative_image.purge
    record = seeded_activity
    record.images.attach(io: StringIO.new(File.binread(Rails.root.join("db/seeds/assets/seed-concert.jpg"))),
      filename: "seed-concert.jpg", content_type: "image/jpeg")
    record.images.attach(image_upload("image.jpg").merge(filename: "seed-concert.jpg"))
    record.images.attach(image_upload("image.jpg").merge(filename: "seed-obsolete.jpg"))
    record.images.attach(image_upload)
    manual_blob_id = record.images.blobs.find_by!(filename: "image.png").id
    # A manually selected has_one image is retained in preference to a seed image.
    aster = demo.user_oshis.find_by!(oshi: Oshi.find_by!(name: "ASTER"))
    aster.representative_image.purge
    aster.representative_image.attach(image_upload)
    manual_single_blob_id = aster.representative_image.blob.id

    service = ActiveStorage::Blob.services.fetch(:test)
    allow(service).to receive(:delete).and_wrap_original do |original, *args|
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      original.call(*args)
    end

    dataset.call
    expect(profile.reload.profile_image.blob.id).not_to eq(original_profile_blob_id)
    expect(representative.reload.representative_image).to be_attached
    expect(record.reload.images.map { |image| image.filename.to_s }).to match_array(%w[seed-concert.jpg image.png])
    expect(record.images.blobs.find_by!(filename: "image.png").id).to eq(manual_blob_id)
    expect(aster.reload.representative_image.blob.id).to eq(manual_single_blob_id)
    expect_seed_images_downloadable
    ids = [ ActiveStorage::Blob.order(:id).pluck(:id), ActiveStorage::Attachment.order(:id).pluck(:id) ]
    dataset.call
    expect([ ActiveStorage::Blob.order(:id).pluck(:id), ActiveStorage::Attachment.order(:id).pluck(:id) ]).to eq(ids)
  end

  it "rolls back DB failures without touching previously stored image files" do
    dataset.call
    profile_image = demo.profile.profile_image
    blob_id = profile_image.blob.id
    bytes = profile_image.download
    demo.update!(admin: true)
    demo.profile.update!(display_name: "変更済み")
    allow(dataset).to receive(:create_subscriptions).and_raise(ActiveRecord::RecordInvalid)
    expect(dataset).not_to receive(:sync_images)
    expect { dataset.call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(demo.admin).to be(true)
    expect(demo.profile.display_name).to eq("変更済み")
    expect(demo.profile.profile_image.blob.id).to eq(blob_id)
    expect(demo.profile.profile_image.download).to eq(bytes)
  end

  it "commits canonical records before image failure and repairs the missing file on retry" do
    service = ActiveStorage::Blob.services.fetch(:test)
    uploads = 0
    allow(service).to receive(:upload).and_wrap_original do |original, *args, **kwargs|
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      uploads += 1
      raise IOError, "simulated disk failure" if uploads == 2

      original.call(*args, **kwargs)
    end
    expect { dataset.call }.to raise_error(IOError, "simulated disk failure")
    expect(User.where(email: emails).count).to eq(5)
    expect(Activity.where(user: User.where(email: emails)).count).to eq(42)
    expect(Subscription.where(user: User.where(email: emails)).count).to eq(12)
    expect(demo.profile.profile_image.download).to eq(File.binread(Rails.root.join("db/seeds/assets/seed-flowers.jpg")))
    missing = demo.user_oshis.find_by!(oshi: Oshi.find_by!(name: "LUMINA")).representative_image.blob
    expect(missing.service.exist?(missing.key)).to be(false)
    attachment_id = missing.attachments.sole.id

    allow(service).to receive(:upload).and_call_original
    dataset.call
    expect(missing.attachments.sole.id).to eq(attachment_id)
    expect_seed_images_downloadable
    expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq([ 12, 12 ])
  end

  it "rejects an outer transaction before any DB or image changes" do
    before = counts
    ActiveRecord::Base.transaction do
      expect { dataset.call }.to raise_error(ArgumentError, /outside an existing DB transaction/)
    end
    expect(counts).to eq(before)
  end
end
