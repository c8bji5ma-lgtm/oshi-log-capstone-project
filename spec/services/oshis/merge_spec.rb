require "rails_helper"
require "tmpdir"
require_relative "../../support/image_attachments"

RSpec.describe Oshis::Merge do
  include ImageAttachments

  let(:source) { create(:oshi, :pending, name: "旧名称") }
  let(:target) { create(:oshi, :approved, name: "正式名称") }

  def merge(source_id: source.id, target_id: target.id)
    described_class.call(source_id: source_id, target_id: target_id)
  end

  def activity_with(*oshis)
    record = build(:activity, :without_oshis, amount: 2500)
    oshis.each { |oshi| record.activity_oshis.build(oshi: oshi) }
    record.save!
    record
  end

  def snapshot
    [ Oshi, UserOshi, Activity, ActivityOshi, Subscription, SubscriptionOshi, OshiAlias,
      ActiveStorage::Attachment, ActiveStorage::Blob, ActiveStorage::VariantRecord ].to_h do |model|
      [ model.name, model.order(:id).map(&:attributes) ]
    end
  end

  def image_snapshot
    ActiveStorage::Blob.order(:id).to_h { |blob| [ blob.id, blob.download ] }
  end

  def prepare_full_merge
    original = create(:user_oshi, oshi: source, started_period: "2020/05", ended_period: "2024")
    retained = create(:user_oshi, user: original.user, oshi: target, started_period: nil)
    original.representative_image.attach(image_upload)
    activity = activity_with(source, target)
    activity.images.attach(image_upload("image.jpg"))
    create(:subscription, oshis: [ source, target ])
    create(:oshi_alias, oshi: source, alias_name: "旧別名")
    create(:oshi_alias, oshi: target, alias_name: "正式別名")
    [ original, retained ]
  end

  describe "input validation" do
    [ nil, "", " ", 0, -1, "0", "-1", "1x", "1.0", 1.0, true, [], {}, " 1" ].each do |value|
      [ :source_id, :target_id ].each do |argument|
        it "rejects #{argument}=#{value.inspect} without any changes" do
          source
          target
          before = snapshot
          expect { merge(**{ argument => value }) }.to raise_error(described_class::InvalidInput)
          expect(snapshot).to eq(before)
        end
      end
    end

    it "rejects the same ID even when one input is a string" do
      expect { merge(target_id: source.id.to_s) }.to raise_error(described_class::InvalidInput)
      expect(source.reload).to be_pending
    end

    [ :source_id, :target_id ].each do |argument|
      it "reports a missing #{argument} and keeps all records" do
        prepare_full_merge
        before = snapshot
        expect { merge(**{ argument => Oshi.maximum(:id) + 1 }) }.to raise_error(ActiveRecord::RecordNotFound)
        expect(snapshot).to eq(before)
      end
    end
  end

  describe "successful merging" do
    it "moves nonduplicate references without changing parent records, attachment IDs or files" do
      personal = create(:user_oshi, oshi: source, started_period: "2023/05")
      personal.representative_image.attach(image_upload)
      activity = activity_with(source)
      activity.images.attach(image_upload("image.jpg"))
      subscription = create(:subscription, oshis: [ source ], amount: 3000)
      alias_record = create(:oshi_alias, oshi: source)
      retained_personal = create(:user_oshi, oshi: target)
      attachment = personal.representative_image.attachment
      activity_link = activity.activity_oshis.first
      subscription_link = subscription.subscription_oshis.first
      parents = [ activity.attributes, subscription.attributes, target.attributes, retained_personal.attributes ]
      attachments = ActiveStorage::Attachment.order(:id).map(&:attributes)
      files = image_snapshot

      result = merge(source_id: source.id.to_s, target_id: target.id.to_s)

      expect(result.id).to eq(target.id)
      expect(Oshi.exists?(source.id)).to be(false)
      expect(personal.reload).to have_attributes(oshi_id: target.id, started_period: "2023/05")
      expect(personal.representative_image.attachment.id).to eq(attachment.id)
      expect(activity_link.reload.oshi_id).to eq(target.id)
      expect(subscription_link.reload.oshi_id).to eq(target.id)
      expect(alias_record.reload.oshi_id).to eq(target.id)
      expect(target.oshi_aliases.pluck(:alias_name)).to contain_exactly(alias_record.alias_name, "旧名称")
      expect([ activity.reload.attributes, subscription.reload.attributes, target.reload.attributes, retained_personal.reload.attributes ]).to eq(parents)
      expect(ActiveStorage::Attachment.order(:id).map(&:attributes)).to eq(attachments)
      expect(image_snapshot).to eq(files)
      expect(activity.activity_oshis.count).to eq(1)
    end

    it "fills each empty period and moves the original attachment before removing the duplicate UserOshi" do
      original, retained = prepare_full_merge
      attachment = original.representative_image.attachment
      attachment_id, blob_id = attachment.id, attachment.blob_id
      files = image_snapshot
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_raise("unexpected purge")
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge_later).and_raise("unexpected purge_later")

      merge

      expect(UserOshi.exists?(original.id)).to be(false)
      expect(retained.reload).to have_attributes(started_period: "2020/05", ended_period: "2024")
      expect(retained.representative_image.attachment).to have_attributes(id: attachment_id, blob_id: blob_id, record_id: retained.id)
      expect(ActiveStorage::Attachment.where(record_type: "UserOshi", record_id: original.id)).to be_empty
      expect(image_snapshot).to eq(files)
    end

    it "keeps the target attachment for equal blobs and removes only the redundant reference without purge" do
      original = create(:user_oshi, oshi: source, ended_period: "2024")
      retained = create(:user_oshi, user: original.user, oshi: target, ended_period: "2024")
      original.representative_image.attach(image_upload)
      retained.representative_image.attach(original.representative_image.blob)
      retained_image = retained.representative_image.attachment
      redundant_id = original.representative_image.attachment.id
      files = image_snapshot
      allow_any_instance_of(ActiveStorage::Attachment).to receive(:purge).and_raise("unexpected purge")
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge_later).and_raise("unexpected purge_later")

      expect { merge }.to change(ActiveStorage::Attachment, :count).by(-1)

      expect(retained.reload).to have_attributes(started_period: "2023", ended_period: "2024")
      expect(retained.representative_image.attachment.id).to eq(retained_image.id)
      expect(ActiveStorage::Attachment.exists?(redundant_id)).to be(false)
      expect(image_snapshot).to eq(files)
    end

    it "preserves the target's nonempty periods and image when the source has empty values" do
      original = create(:user_oshi, oshi: source, started_period: nil)
      retained = create(:user_oshi, user: original.user, oshi: target, ended_period: "2024/05")
      retained.representative_image.attach(image_upload)
      image = retained.representative_image.attachment.attributes
      merge
      expect(retained.reload).to have_attributes(started_period: "2023", ended_period: "2024/05")
      expect(retained.representative_image.attachment.attributes).to eq(image)
    end

    it "preserves empty periods when both registrations are empty" do
      original = create(:user_oshi, oshi: source, started_period: nil)
      retained = create(:user_oshi, user: original.user, oshi: target, started_period: nil)
      merge
      expect(retained.reload).to have_attributes(started_period: nil, ended_period: nil)
      expect(retained.representative_image).not_to be_attached
    end

    it "retains target join IDs and collapses duplicate activity/subscription pairs" do
      activity = activity_with(source, target)
      subscription = create(:subscription, oshis: [ source, target ])
      retained_activity_link = activity.activity_oshis.find_by!(oshi: target).id
      retained_subscription_link = subscription.subscription_oshis.find_by!(oshi: target).id
      parents = [ activity.attributes, subscription.attributes ]
      merge
      expect(activity.reload.activity_oshis.pluck(:id)).to eq([ retained_activity_link ])
      expect(subscription.reload.subscription_oshis.pluck(:id)).to eq([ retained_subscription_link ])
      expect([ activity.attributes, subscription.attributes ]).to eq(parents)
    end

    it "retains other oshi links and aliases, deduplicates aliases exactly, and keeps letter case distinct" do
      other = create(:oshi)
      activity = activity_with(source, target, other)
      subscription = create(:subscription, oshis: [ source, target, other ])
      create(:oshi_alias, oshi: source, alias_name: "共通別名")
      shared = create(:oshi_alias, oshi: target, alias_name: "共通別名")
      create(:oshi_alias, oshi: source, alias_name: "Example")
      create(:oshi_alias, oshi: target, alias_name: "example")
      existing_name = create(:oshi_alias, oshi: source, alias_name: source.name)
      untouched = create(:oshi_alias, oshi: other, alias_name: "共通別名")
      merge
      expect(activity.reload.oshi_ids).to match_array([ target.id, other.id ])
      expect(subscription.reload.oshi_ids).to match_array([ target.id, other.id ])
      expect(target.oshi_aliases.pluck(:alias_name)).to contain_exactly("共通別名", "Example", "example", "旧名称")
      expect(shared.reload.oshi_id).to eq(target.id)
      expect(existing_name.reload.oshi_id).to eq(target.id)
      expect(untouched.reload.oshi_id).to eq(other.id)
    end

    it "does not duplicate a source-name alias already present on the target" do
      existing = create(:oshi_alias, oshi: target, alias_name: source.name)
      expect { merge }.not_to change(OshiAlias, :count)
      expect(existing.reload.oshi_id).to eq(target.id)
    end

    it "does not impose a pending/approved restriction or change the target state" do
      source.update!(status: :approved)
      target.update!(status: :rejected)
      merge
      expect(target.reload).to be_rejected
    end
  end

  describe "conflicts" do
    [ :started_period, :ended_period ].each do |attribute|
      it "reports a different nonempty #{attribute} and leaves every table and file intact" do
        original, retained = prepare_full_merge
        retained.update!(attribute => "2025/01")
        before, files = snapshot, image_snapshot
        expect { merge }.to raise_error(described_class::Conflict) { |error|
          expect(error.user_id).to eq(original.user_id)
          expect(error.attribute).to eq(attribute)
        }
        expect(snapshot).to eq(before)
        expect(image_snapshot).to eq(files)
      end
    end

    it "treats a year and a month in that same year as different nonempty periods" do
      original = create(:user_oshi, oshi: source, started_period: "2023")
      create(:user_oshi, user: original.user, oshi: target, started_period: "2023/01")
      expect { merge }.to raise_error(described_class::Conflict) { |error| expect(error.attribute).to eq(:started_period) }
    end

    it "rejects different blobs even if their image bytes are identical" do
      original, retained = prepare_full_merge
      retained.representative_image.attach(image_upload)
      expect(original.representative_image.blob_id).not_to eq(retained.representative_image.blob_id)
      expect(original.representative_image.download).to eq(retained.representative_image.download)
      before, files = snapshot, image_snapshot
      expect { merge }.to raise_error(described_class::Conflict) { |error| expect(error.attribute).to eq(:representative_image) }
      expect(snapshot).to eq(before)
      expect(image_snapshot).to eq(files)
    end
  end

  describe "rollback after persistence" do
    [ [ :merge_user_oshis, nil ], [ :merge_links, :activity_id ],
      [ :merge_links, :subscription_id ], [ :merge_aliases, nil ] ].each do |stage, parent_key|
      it "rolls back actual writes after #{stage} #{parent_key}" do
        prepare_full_merge
        before, files = snapshot, image_snapshot
        service = described_class.new(source_id: source.id, target_id: target.id)
        fault = RuntimeError.new("failure after persistence")
        allow(service).to receive(stage).and_wrap_original do |original_method, *args|
          original_method.call(*args)
          if parent_key.nil? || args.last == parent_key
            expect(snapshot).not_to eq(before)
            raise fault
          end
        end
        expect { service.call }.to raise_error { |error| expect(error).to equal(fault) }
        expect(snapshot).to eq(before)
        expect(image_snapshot).to eq(files)
      end
    end

    it "rolls back even a completed source deletion when its callback fails" do
      prepare_full_merge
      before, files = snapshot, image_snapshot
      fault = RuntimeError.new("failure after source deletion")
      allow_any_instance_of(Oshi).to receive(:destroy!).and_wrap_original do |original_method|
        original_method.call
        expect(Oshi.exists?(source.id)).to be(false)
        raise fault
      end
      expect { merge }.to raise_error { |error| expect(error).to equal(fault) }
      expect(snapshot).to eq(before)
      expect(image_snapshot).to eq(files)
    end

    it "rolls back a real alias validation failure and returns its cause" do
      prepare_full_merge
      source.update_column(:name, " ")
      before, files = snapshot, image_snapshot
      expect { merge }.to raise_error(ActiveRecord::RecordInvalid) { |error| expect(error.record).to be_a(OshiAlias) }
      expect(snapshot).to eq(before)
      expect(image_snapshot).to eq(files)
    end

    it "isolates failures even when a caller rescues inside an existing transaction" do
      prepare_full_merge
      source.update_column(:name, " ")
      before = snapshot
      Oshi.transaction do
        expect { merge }.to raise_error(ActiveRecord::RecordInvalid)
        expect(snapshot).to eq(before)
        expect(create(:oshi)).to be_persisted
      end
    end
  end

  describe "locking" do
    it "locks UserOshi and parents before ordered Oshi locks, and all locks before writes" do
      prepare_full_merge
      statements = []
      listener = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      begin
        merge
      ensure
        ActiveSupport::Notifications.unsubscribe(listener)
      end
      lock_index = ->(table) { statements.index { |sql| sql.include?("FROM \"#{table}\"") && sql.include?("FOR UPDATE") } }
      oshi_lock = lock_index.call("oshis")
      %w[user_oshis activities subscriptions].each do |table|
        expect(lock_index.call(table)).to be < oshi_lock
      end
      expect(statements[oshi_lock]).to include('ORDER BY "oshis"."id" ASC')
      first_write = statements.index { |sql| sql.match?(/\A(?:UPDATE|DELETE|INSERT)/) }
      %w[oshis activity_oshis subscription_oshis oshi_aliases active_storage_attachments].each do |table|
        expect(lock_index.call(table)).to be < first_write
      end
    end

    it "refuses a changed related set instead of operating on unlocked parents" do
      prepare_full_merge
      service = described_class.new(source_id: source.id, target_id: target.id)
      inserted = false
      allow(service).to receive(:pair_scope).and_wrap_original do |original_method, model|
        scope = original_method.call(model)
        if model == ActivityOshi && !inserted
          allow(scope).to receive(:pluck).with(:activity_id).and_return([])
          allow(scope).to receive(:distinct).and_return(scope)
          inserted = true
        end
        scope
      end
      before = snapshot
      expect { service.call }.to raise_error(described_class::ConcurrentChange)
      expect(snapshot).to eq(before)
    end
  end

  describe "committed transactions" do
    # Real commits exercise Active Storage's after_commit callbacks; fixture
    # transactions would hide accidental purge jobs and cross-connection races.
    self.use_transactional_tests = false

    around do |example|
      raise "Merge specs require the test environment" unless Rails.env.test?

      models = [ ActiveStorage::VariantRecord, ActiveStorage::Attachment,
        ActivityOshi, SubscriptionOshi, OshiAlias, UserOshi, Activity, Subscription,
        Oshi, User, ActiveStorage::Blob ]
      baseline_ids = models.to_h { |model| [ model, model.pluck(:id) ] }
      original_services = ActiveStorage::Blob.services
      original_service = ActiveStorage::Blob.service
      original_adapter = ActiveJob::Base.queue_adapter
      Dir.mktmpdir("oshi-merge-spec-") do |directory|
        disk = ActiveStorage::Service::DiskService.new(root: directory)
        disk.name = "test"
        ActiveStorage::Blob.services = { "test" => disk, test: disk }
        ActiveStorage::Blob.service = disk
        ActiveJob::Base.queue_adapter = :test
        begin
          example.run
        ensure
          # Cleanup only this example's rows, in FK order, without storage jobs.
          models.each { |model| model.where.not(id: baseline_ids.fetch(model)).delete_all }
          ActiveStorage::Blob.services = original_services
          ActiveStorage::Blob.service = original_service
          ActiveJob::Base.queue_adapter = original_adapter
        end
      end
    end

    it "commits the existing attachment's ownership move without any purge job or lost file" do
      original, retained = prepare_full_merge
      attachment_id = original.representative_image.attachment.id
      blob_id = original.representative_image.blob.id
      bytes = original.representative_image.download
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect(Oshi.connection.transaction_open?).to be(false)

      merge

      expect(Oshi.connection.transaction_open?).to be(false)
      expect(Oshi.exists?(source.id)).to be(false)
      expect(retained.reload.representative_image.attachment).to have_attributes(id: attachment_id, blob_id: blob_id)
      expect(retained.representative_image.download).to eq(bytes)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).not_to include(ActiveStorage::PurgeJob)
    end

    it "commits same-blob deduplication without scheduling purge or losing the retained image" do
      original = create(:user_oshi, oshi: source)
      retained = create(:user_oshi, user: original.user, oshi: target)
      original.representative_image.attach(image_upload)
      retained.representative_image.attach(original.representative_image.blob)
      retained_id = retained.representative_image.attachment.id
      bytes = original.representative_image.download
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      merge

      expect(retained.reload.representative_image.attachment.id).to eq(retained_id)
      expect(retained.representative_image.download).to eq(bytes)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).not_to include(ActiveStorage::PurgeJob)
    end

    it "restores every row, image owner and original bytes on failure without an outer fixture transaction" do
      original, = prepare_full_merge
      source.update_column(:name, " ")
      before = snapshot
      image_id = original.representative_image.attachment.id
      bytes = original.representative_image.download
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect { merge }.to raise_error(ActiveRecord::RecordInvalid)
      expect(snapshot).to eq(before)
      expect(original.reload.representative_image.attachment.id).to eq(image_id)
      expect(original.representative_image.download).to eq(bytes)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
    end

    it "waits for an existing activity save without reversing its parent-first locking order" do
      source_id, target_id = source.id, target.id
      activity = activity_with(source)
      create(:user_oshi, user: activity.user, oshi: source)
      create(:user_oshi, user: activity.user, oshi: target)
      locked, release, started, results = Queue.new, Queue.new, Queue.new, Queue.new
      saver = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Activity.transaction do
            current = Activity.lock.find(activity.id)
            locked << true
            release.pop
            Activities::Save.call(activity: current, attributes: { title: "並行更新" }, oshi_ids: [ source_id, target_id ])
          end
          results << :saved
        rescue StandardError => error
          results << error
        end
      end
      merger = nil
      begin
        locked.pop
        merger = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            started << connection.select_value("SELECT pg_backend_pid()")
            described_class.call(source_id: source_id, target_id: target_id)
            results << :merged
          rescue StandardError => error
            results << error
          end
        end
        pid = started.pop
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        loop do
          break if Oshi.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
          raise "Merge did not wait for the activity lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.01
        end
        release << true
        [ saver, merger ].each { |thread| expect(thread.join(5)).not_to be_nil }
        expect([ results.pop, results.pop ]).to contain_exactly(:saved, :merged)
        expect(activity.reload.title).to eq("並行更新")
        expect(activity.oshi_ids).to eq([ target_id ])
        expect(Oshi.exists?(source_id)).to be(false)
      ensure
        release << true
        [ saver, merger ].compact.each do |thread|
          thread.kill if thread.alive? && !thread.join(5)
          thread.join
        end
      end
    end
  end
end
