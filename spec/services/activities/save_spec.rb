require "rails_helper"
require "timeout"
require_relative "../../support/image_attachments"

RSpec.describe Activities::Save do
  include ImageAttachments
  def save_activity(activity, oshi_ids: nil, attributes: {}, emotion_ids: nil, new_images: [],
    expected_lock_version: nil)
    ids = oshi_ids || activity.activity_oshis.map(&:oshi_id)
    Oshi.where(id: ids).find_each do |oshi|
      UserOshi.find_or_create_by!(user: activity.user, oshi: oshi)
    end
    described_class.call(activity: activity, oshi_ids: oshi_ids, attributes: attributes, emotion_ids: emotion_ids,
      new_images: new_images, expected_lock_version: expected_lock_version)
  end

  describe "creation" do
    it "rejects an unregistered oshi without leaving a parent or link" do
      activity = build(:activity, :without_oshis)
      unregistered = create(:oshi)

      expect do
        described_class.call(activity: activity, oshi_ids: [ unregistered.id ])
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(activity.errors[:activity_oshis]).to include("must belong to oshis registered by the activity user")
      expect(activity).not_to be_persisted
      expect(ActivityOshi.where(oshi: unregistered)).to be_empty
    end

    it "rejects another user's pending oshi even when it exists" do
      activity = build(:activity, :without_oshis)
      other = create(:user)
      pending = create(:oshi, :pending, created_by_user: other)
      create(:user_oshi, user: other, oshi: pending)

      expect do
        described_class.call(activity: activity, oshi_ids: [ pending.id ])
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
    it "validates registrations against an owner supplied in attributes" do
      original_owner = create(:user)
      replacement_owner = create(:user)
      oshi = create(:oshi)
      create(:user_oshi, user: original_owner, oshi: oshi)
      activity = build(:activity, :without_oshis, user: original_owner)
      activity.activity_oshis.build(oshi: oshi)
      activity.save!
      original = activity.attributes
      links = activity.activity_oshis.pluck(:id, :oshi_id)

      expect do
        described_class.call(activity: activity, attributes: { user: replacement_owner, title: "保存しない" },
          oshi_ids: [ oshi.id ])
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(activity.reload.attributes).to eq(original)
      expect(activity.activity_oshis.pluck(:id, :oshi_id)).to eq(links)
    end


    [ 1, 2 ].each do |count|
      it "saves an activity with #{count} oshis" do
        activity = build(:activity, :without_oshis)
        oshis = create_list(:oshi, count)
        expect(save_activity(activity, oshi_ids: oshis.map(&:id))).to eq(activity)
        expect(activity.reload.oshis).to match_array(oshis)
      end
    end

    it "saves links already built on a new activity when IDs are omitted" do
      activity = build(:activity)
      save_activity(activity)
      expect(activity.reload.activity_oshis.count).to eq(1)
    end

    it "rejects zero oshis without leaving a parent" do
      activity = build(:activity, :without_oshis)
      expect do
        expect { save_activity(activity, oshi_ids: []) }.to raise_error(ActiveRecord::RecordInvalid)
      end.not_to change(Activity, :count)
      expect(activity.errors[:activity_oshis]).to include("must include at least one oshi")
    end

    it "rolls back children when the parent is invalid" do
      activity = build(:activity, :without_oshis, title: nil)
      oshi = create(:oshi)
      counts = [ Activity.count, ActivityOshi.count ]
      expect { save_activity(activity, oshi_ids: [ oshi.id ]) }.to raise_error(ActiveRecord::RecordInvalid)
      expect([ Activity.count, ActivityOshi.count ]).to eq(counts)
    end

    it "leaves no parent when a child is invalid" do
      activity = build(:activity, :without_oshis)
      counts = [ Activity.count, ActivityOshi.count ]
      invalid_id = Oshi.maximum(:id).to_i + 1
      expect { save_activity(activity, oshi_ids: [ invalid_id ]) }.to raise_error(ActiveRecord::RecordInvalid)
      expect([ Activity.count, ActivityOshi.count ]).to eq(counts)
    end

    it "rolls back an inserted parent when child persistence fails" do
      activity = build(:activity)
      link = activity.activity_oshis.first
      counts = [ Activity.count, ActivityOshi.count ]
      allow(link).to receive(:save) do
        expect(Activity.exists?(activity.id)).to be(true)
        raise ActiveRecord::RecordNotSaved, "simulated child insertion failure"
      end
      expect { save_activity(activity) }.to raise_error(ActiveRecord::RecordNotSaved)
      expect([ Activity.count, ActivityOshi.count ]).to eq(counts)
    end

    it "normalizes duplicate integer and string IDs into one link" do
      activity = build(:activity, :without_oshis)
      oshi = create(:oshi)
      save_activity(activity, oshi_ids: [ oshi.id, oshi.id.to_s, oshi.id ])
      expect(activity.reload.activity_oshis.count).to eq(1)
    end
  end

  describe "editing" do
    it "updates only attributes when IDs are omitted" do
      activity = create(:activity)
      ids = activity.oshi_ids
      link_id = activity.activity_oshis.first.id
      save_activity(activity, attributes: { title: "更新", amount: 0 })
      expect(activity.reload.title).to eq("更新")
      expect(activity.amount).to eq(0)
      expect(activity.oshi_ids).to eq(ids)
      expect(activity.activity_oshis.first.id).to eq(link_id)
    end

    it "replaces one oshi with another without an intermediate zero-link state" do
      activity = create(:activity)
      replacement = create(:oshi)
      original_link_id = activity.activity_oshis.first.id
      link_counts_after_removal = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        if payload[:sql].match?(/\ADELETE FROM "activity_oshis"/)
          link_counts_after_removal << ActivityOshi.where(activity_id: activity.id).count
        end
      end
      begin
        save_activity(activity, oshi_ids: [ replacement.id ])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
      expect(activity.reload.oshis).to contain_exactly(replacement)
      expect(ActivityOshi.exists?(original_link_id)).to be(false)
      expect(link_counts_after_removal).to eq([ 1 ])
    end

    it "changes one oshi into multiple oshis, preserving the retained link" do
      activity = create(:activity)
      link = activity.activity_oshis.first
      additional = create(:oshi)
      save_activity(activity, oshi_ids: [ link.oshi_id, additional.id ])
      expect(activity.reload.oshi_ids).to match_array([ link.oshi_id, additional.id ])
      expect(activity.activity_oshis.find_by(oshi_id: link.oshi_id).id).to eq(link.id)
    end

    it "changes multiple oshis into one oshi" do
      activity = create(:activity, :multiple_oshis)
      retained = activity.oshis.first
      save_activity(activity, oshi_ids: [ retained.id ])
      expect(activity.reload.oshis).to contain_exactly(retained)
    end

    it "rejects removing all oshis, rolling back attributes too" do
      activity = create(:activity, :multiple_oshis)
      original_title = activity.title
      original_ids = activity.oshi_ids
      expect do
        save_activity(activity, oshi_ids: [], attributes: { title: "失敗" })
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(activity.reload.title).to eq(original_title)
      expect(activity.oshi_ids).to match_array(original_ids)
    end

    it "rolls back attributes and links when adding an invalid oshi" do
      activity = create(:activity)
      original_title = activity.title
      original_ids = activity.oshi_ids
      expect do
        save_activity(activity, oshi_ids: [ Oshi.maximum(:id).to_i + 1 ], attributes: { title: "失敗" })
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(activity.reload.title).to eq(original_title)
      expect(activity.oshi_ids).to eq(original_ids)
    end

    it "rolls back additions and attributes if a later removal fails" do
      activity = create(:activity)
      replacement = create(:oshi)
      original_title = activity.title
      original_ids = activity.oshi_ids
      original_count = ActivityOshi.count
      allow(activity).to receive(:save!).and_wrap_original do |original|
        original.call
        # Fail after the new link and parent have actually been saved.
        allow(activity.activity_oshis).to receive(:where).and_raise(ActiveRecord::RecordNotDestroyed)
      end
      expect do
        save_activity(activity, oshi_ids: [ replacement.id ], attributes: { title: "失敗" })
      end.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(activity.reload.title).to eq(original_title)
      expect(activity.oshi_ids).to eq(original_ids)
      expect(ActivityOshi.count).to eq(original_count)
    end

    it "refreshes stale associations before applying the requested links" do
      activity = create(:activity)
      activity.activity_oshis.load
      additional = create(:oshi)
      create(:activity_oshi, activity: Activity.find(activity.id), oshi: additional)
      save_activity(activity, oshi_ids: [ additional.id, additional.id ])
      expect(activity.reload.oshis).to contain_exactly(additional)
    end

    it "locks the parent before an attribute update" do
      activity = create(:activity)
      statements = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql]
      end
      begin
        save_activity(activity, attributes: { title: "ロック確認" })
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
      lock_index = statements.index { |sql| sql.include?('FROM "activities"') && sql.include?("FOR UPDATE") }
      update_index = statements.index { |sql| sql.start_with?('UPDATE "activities"') }
      expect(lock_index).not_to be_nil
      expect(update_index).not_to be_nil
      expect(lock_index).to be < update_index
    end

    it "rejects a stale expected version before changing attributes or links" do
      activity = create(:activity)
      stale_version = activity.lock_version
      replacement = create(:oshi)
      create(:user_oshi, user: activity.user, oshi: replacement)
      described_class.call(activity: Activity.find(activity.id), attributes: { title: "先行更新" },
        oshi_ids: [ replacement.id ], expected_lock_version: stale_version)
      latest = activity.reload.attributes
      latest_ids = activity.oshi_ids

      stale_replacement = create(:oshi)
      create(:user_oshi, user: activity.user, oshi: stale_replacement)
      expect do
        described_class.call(activity: activity, attributes: { title: "古い更新" }, oshi_ids: [ stale_replacement.id ],
          expected_lock_version: stale_version)
      end.to raise_error(ActiveRecord::StaleObjectError)
      expect(activity.reload.attributes).to eq(latest)
      expect(activity.oshi_ids).to eq(latest_ids)
    end

    it "advances the parent version for a links-only update" do
      activity = create(:activity)
      version = activity.lock_version
      replacement = create(:oshi)
      create(:user_oshi, user: activity.user, oshi: replacement)
      described_class.call(activity: activity, oshi_ids: [ replacement.id ], expected_lock_version: version)
      expect(activity.reload.lock_version).to be > version
    end
  end

  describe "emotion tags" do
    include_context "emotion master data"

    let(:happy) { Emotion.find_by!(name: "嬉しい") }
    let(:moved) { Emotion.find_by!(name: "感動") }

    it "saves new activities with multiple deduplicated tags or no tags" do
      activity = build(:activity)
      described_class.call(activity: activity, emotion_ids: [ happy.id, moved.id.to_s, happy.id.to_s ])
      expect(activity.reload.emotions).to eq([ happy, moved ])
      expect(activity.activity_emotions.count).to eq(2)
      untagged = build(:activity)
      described_class.call(activity: untagged, emotion_ids: [])
      expect(untagged.reload.emotions).to be_empty
    end

    it "preserves omitted tags, replaces explicit selections and permits clearing all tags" do
      activity = create(:activity, emotions: [ happy ])
      link_id = activity.activity_emotions.first.id
      save_activity(activity, attributes: { title: "本文変更" })
      expect(activity.reload.emotions).to eq([ happy ])
      expect(activity.activity_emotions.first.id).to eq(link_id)
      save_activity(activity, emotion_ids: [ moved.id ])
      expect(activity.reload.emotions).to eq([ moved ])
      save_activity(activity, emotion_ids: [])
      expect(activity.reload.emotions).to be_empty
    end

    it "rolls back new tags, oshis and the parent for an invalid image" do
      activity = build(:activity)
      counts = [ Activity.count, ActivityOshi.count, ActivityEmotion.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      expect do
        described_class.call(activity: activity, emotion_ids: [ happy.id ], new_images: [ image_upload("invalid.txt") ])
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect([ Activity.count, ActivityOshi.count, ActivityEmotion.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end

    it "rolls back tag additions and removals with invalid scalars, oshis or images" do
      activity = create(:activity, emotions: [ happy ])
      original = activity.attributes
      original_oshi_ids = activity.oshi_ids
      [ { attributes: { title: "" } }, { oshi_ids: [] }, { new_images: [ image_upload("invalid.txt") ] } ].each do |invalid|
        expect do
          described_class.call(activity: activity, emotion_ids: [ moved.id ], **invalid)
        end.to raise_error(ActiveRecord::RecordInvalid)
        expect(activity.reload.attributes).to eq(original)
        expect(activity.emotions).to eq([ happy ])
        expect(activity.oshi_ids).to eq(original_oshi_ids)
      end
    end

    it "rolls back tags when a later oshi removal fails" do
      activity = create(:activity, emotions: [ happy ])
      replacement = create(:oshi)
      create(:user_oshi, user: activity.user, oshi: replacement)
      original = activity.attributes
      original_oshi_ids = activity.oshi_ids
      allow(activity).to receive(:save!).and_wrap_original do |method|
        method.call
        allow(activity.activity_oshis).to receive(:where).and_raise(ActiveRecord::RecordNotDestroyed)
      end
      expect do
        described_class.call(activity: activity, attributes: { title: "失敗" }, oshi_ids: [ replacement.id ], emotion_ids: [])
      end.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(activity.reload.attributes).to eq(original)
      expect(activity.emotions).to eq([ happy ])
      expect(activity.oshi_ids).to eq(original_oshi_ids)
    end

    it "does not reuse a stale tag association when replacing tags" do
      activity = create(:activity, emotions: [ happy ])
      activity.emotions.load
      Activity.find(activity.id).emotions << moved
      save_activity(activity, emotion_ids: [ happy.id ])
      expect(activity.reload.emotions).to eq([ happy ])
    end
  end

  describe "appending new images" do
    let(:activity) { create(:activity) }

    before do
      activity.images.attach(image_upload)
    end

    [ nil, [] ].each do |uploads|
      it "retains existing images when new_images is #{uploads.inspect}" do
        original = activity.images.first.blob_id
        save_activity(activity, attributes: { title: "更新" }, new_images: uploads)
        expect(activity.reload.images.map(&:blob_id)).to eq([ original ])
      end
    end

    it "appends images and retains original bytes" do
      original = activity.images.first.blob_id
      save_activity(activity, new_images: [ image_upload("image.webp") ])
      expect(activity.reload.images.count).to eq(2)
      expect(activity.images.map(&:blob_id)).to include(original)
      expect(activity.images.last.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.webp")))
    end

    it "accepts a new batch totaling exactly 10 MiB" do
      save_activity(activity, new_images: [ image_upload(size: 5.megabytes), image_upload("image.webp", size: 5.megabytes) ])
      expect(activity.reload.images.count).to eq(3)
    end

    it "rejects a batch over 10 MiB and rolls back scalar, links and pending images" do
      original = activity.reload.attributes
      original_oshi_ids = activity.oshi_ids
      original_blob_ids = activity.images.map(&:blob_id)
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      replacement = create(:oshi)
      create(:user_oshi, user: activity.user, oshi: replacement)
      files = [ image_upload(size: 5.megabytes), image_upload("image.webp", size: 5.megabytes + 1) ]

      expect do
        save_activity(activity, attributes: { title: "変更しない" }, oshi_ids: [ replacement.id ], new_images: files)
      end.to raise_error(ActiveRecord::RecordInvalid, /送信合計を10 MiB以下/)
      expect(activity.reload.attributes).to eq(original)
      expect(activity.oshi_ids).to eq(original_oshi_ids)
      expect(activity.images.map(&:blob_id)).to eq(original_blob_ids)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end

    it "does not count saved images and permits separate batches up to 10 MiB" do
      2.times { save_activity(activity, new_images: [ image_upload(size: 10.megabytes) ]) }
      expect(activity.reload.images.count).to eq(3)
    end

    it "applies the same limit to image attributes used by trusted callers" do
      files = [ image_upload(size: 5.megabytes), image_upload("image.webp", size: 5.megabytes + 1) ]
      expect { save_activity(activity, attributes: { images: files }) }
        .to raise_error(ActiveRecord::RecordInvalid, /送信合計を10 MiB以下/)
      expect(activity.reload.images.count).to eq(1)
    end

    it "refreshes stale attachments under the parent lock before appending" do
      activity.images.blobs.load
      other_instance = Activity.find(activity.id)
      other_instance.images.attach(image_upload("image.jpg"))
      save_activity(activity, new_images: [ image_upload("image.webp") ])
      expect(activity.reload.images.map { |image| image.filename.to_s }).to match_array(%w[image.png image.jpg image.webp])
    end

    it "rejects a stale expected version before assigning a pending image" do
      stale_version = activity.lock_version
      save_activity(Activity.find(activity.id), attributes: { title: "先行更新" },
        expected_lock_version: stale_version)
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      expect(activity).not_to receive(:images=)
      expect do
        save_activity(activity, new_images: [ image_upload("image.webp") ],
          expected_lock_version: stale_version)
      end.to raise_error(ActiveRecord::StaleObjectError)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end

    it "rolls back scalar, links and images when the new image is invalid" do
      original_title = activity.title
      original_ids = activity.oshi_ids
      original_blobs = activity.images.map(&:blob_id)
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      replacement = create(:oshi)
      expect do
        described_class.call(activity: activity, attributes: { title: "失敗" }, oshi_ids: [ replacement.id ], new_images: [ image_upload("invalid.txt") ])
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(activity.reload.title).to eq(original_title)
      expect(activity.oshi_ids).to eq(original_ids)
      expect(activity.images.map(&:blob_id)).to eq(original_blobs)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
    end
  end
  describe "image attachments through attributes" do
    [ 1, 2 ].each do |count|
      it "creates an activity with #{count} original images" do
        activity = build(:activity, :without_oshis)
        oshi = create(:oshi)
        save_activity(activity, oshi_ids: [ oshi.id ], attributes: { images: Array.new(count) { image_upload } })
        expect(activity.reload.images.size).to eq(count)
        expect(activity.oshi_ids).to eq([ oshi.id ])
        activity.images.each do |image|
          expect(image.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
        end
      end
    end

    it "does not persist the activity, links, blobs, or attachments for an invalid image" do
      activity = build(:activity, :without_oshis)
      oshi = create(:oshi)
      models = [ Activity, ActivityOshi, ActiveStorage::Blob, ActiveStorage::Attachment ]
      counts = models.map(&:count)
      expect do
        save_activity(activity, oshi_ids: [ oshi.id ], attributes: { images: [ image_upload("invalid.txt") ] })
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(models.map(&:count)).to eq(counts)
    end

    it "rolls back an existing activity and its links when pending images are invalid" do
      activity = create(:activity)
      original_title = activity.title
      original_ids = activity.oshi_ids
      replacement = create(:oshi)
      expect do
        save_activity(activity, oshi_ids: [ replacement.id ], attributes: { title: "失敗", images: [ image_upload("invalid.txt") ] })
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(activity.reload.title).to eq(original_title)
      expect(activity.oshi_ids).to eq(original_ids)
      expect(activity.images).not_to be_attached
    end
  end

  describe "concurrent updates on separate connections" do
    self.use_transactional_tests = false

    it "commits one update and rejects the other snapshot as stale" do
      activity = create(:activity)
      activity_id = activity.id
      create(:user_oshi, user: activity.user, oshi: activity.oshis.sole)
      user_id = activity.user_id
      oshi_ids = activity.oshi_ids
      ready = Queue.new
      release = Queue.new
      results = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            candidate = Activity.find(activity.id)
            expected_version = candidate.lock_version
            ready << true
            release.pop
            described_class.call(activity: candidate, attributes: { title: "同時更新#{index}" },
              expected_lock_version: expected_version)
            results << [ :saved, index ]
          rescue StandardError => error
            results << [ :failed, error ]
          end
        end
      end
      Timeout.timeout(10) { 2.times { ready.pop } }
      2.times { release << true }
      threads.each { |thread| expect(thread.join(10)).to eq(thread) }
      outcomes = 2.times.map { results.pop }
      saved = outcomes.select { |status, _| status == :saved }
      failed = outcomes.select { |status, _| status == :failed }
      expect(saved.size).to eq(1)
      expect(failed.map(&:last)).to all(be_a(ActiveRecord::StaleObjectError))
      expect(activity.reload.title).to eq("同時更新#{saved.sole.last}")
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      ActivityOshi.where(activity_id: activity_id).delete_all if activity_id
      Activity.where(id: activity_id).delete_all if activity_id
      UserOshi.where(user_id: user_id, oshi_id: oshi_ids).delete_all if user_id && oshi_ids
      Oshi.where(id: oshi_ids).delete_all if oshi_ids
      User.where(id: user_id).delete_all if user_id
    end
  end
end
