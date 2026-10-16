require "rails_helper"
require "timeout"
require_relative "../../support/image_attachments"
require_relative "../../support/user_oshi_images"

RSpec.describe "Committed oshi image operations" do
  include ImageAttachments
  include UserOshiImages
  self.use_transactional_tests = false

  around do |example|
    raise "Image specs require the test environment" unless Rails.env.test?

    models = [ ActiveStorage::VariantRecord, ActiveStorage::Attachment, Profile, UserOshi, Oshi, User, ActiveStorage::Blob ]
    baseline = models.to_h { |model| [ model, model.pluck(:id) ] }
    services = ActiveStorage::Blob.services
    service = ActiveStorage::Blob.service
    adapter = ActiveJob::Base.queue_adapter
    Dir.mktmpdir("oshi-library-spec-") do |directory|
      disk = ActiveStorage::Service::DiskService.new(root: directory)
      disk.name = "test"
      ActiveStorage::Blob.services = { "test" => disk, test: disk }
      ActiveStorage::Blob.service = disk
      ActiveJob::Base.queue_adapter = :test
      begin
        example.run
      ensure
        models.each { |model| model.where.not(id: baseline.fetch(model)).delete_all }
        ActiveStorage::Blob.services = services
        ActiveStorage::Blob.service = service
        ActiveJob::Base.queue_adapter = adapter
      end
    end
  end

  let(:record) { create(:user_oshi) }

  def save_images(count)
    UserOshis::Save.call(user_oshi: record, new_images: Array.new(count) { library_upload })
  end

  # Hold the first transaction after it has taken the UserOshi lock, then prove
  # the second connection is waiting for a PostgreSQL lock before releasing it.
  def race(first_options, second_options)
    first = UserOshi.find(record.id)
    parent_id = record.id
    locked, release, pid, results = Queue.new, Queue.new, Queue.new, Queue.new
    allow(first).to receive(:validate!).and_wrap_original do |method|
      locked << true
      Timeout.timeout(10) { release.pop }
      method.call
    end
    threads = []
    begin
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          UserOshis::Save.call(user_oshi: first, **first_options)
          results << :saved
        rescue StandardError => error
          results << error.class
        end
      end
      Timeout.timeout(10) { locked.pop }
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          second = UserOshi.find(parent_id)
          second.image_library # Simulate stale preloaded attachments.
          pid << connection.select_value("SELECT pg_backend_pid()")
          UserOshis::Save.call(user_oshi: second, **second_options)
          results << :saved
        rescue StandardError => error
          results << error.class
        end
      end
      backend = Timeout.timeout(10) { pid.pop }.to_i
      Timeout.timeout(10) do
        loop do
          wait = ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{backend}")
          break if wait == "Lock"
          sleep 0.01
        end
      end
      release << true
      threads.each { |thread| expect(thread.join(10)).not_to be_nil }
      Array.new(2) { Timeout.timeout(5) { results.pop } }
    ensure
      release << true
      threads.each do |thread|
        thread.kill if thread.alive? && !thread.join(10)
        thread.join
      end
    end
  end

  it "serializes concurrent uploads at 29 images, rejects the loser, and leaves no orphan blobs" do
    save_images(29)
    counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    outcomes = race({ new_images: [ library_upload ] }, { new_images: [ library_upload ] })
    expect(outcomes).to contain_exactly(:saved, ActiveRecord::RecordInvalid)
    expect(record.reload.image_count).to eq(30)
    expect(ActiveStorage::Blob.count).to eq(counts[0] + 1)
    expect(ActiveStorage::Attachment.count).to eq(counts[1] + 1)
    expect(ActiveStorage::Blob.unattached).to be_empty
  end

  it "refuses implicit deletion when a concurrent selection makes the target representative" do
    save_images(2)
    id = record.reload.image_library.last.id.to_s
    outcomes = race({ representative_image_id: id }, { remove_image_id: id })
    expect(outcomes).to contain_exactly(:saved, ActiveRecord::RecordInvalid)
    expect(record.reload.image_count).to eq(2)
    expect(record.representative_image.blob_id).to eq(record.image_library.last.blob_id)
  end

  it "refuses selection when a concurrent deletion has removed the target" do
    save_images(2)
    original = record.reload.representative_image.blob_id
    id = record.image_library.last.id.to_s
    outcomes = race({ remove_image_id: id }, { representative_image_id: id })
    expect(outcomes).to contain_exactly(:saved, ActiveRecord::RecordNotFound)
    expect(record.reload.image_count).to eq(1)
    expect(record.representative_image.blob_id).to eq(original)
  end

  it "preserves former representative bytes even after replacement purge jobs actually run" do
    record.representative_image.attach(image_upload("image.jpg"))
    previous = record.representative_image.blob
    save_images(1)
    UserOshis::Save.call(user_oshi: record, representative_image_id: record.reload.image_library.last.id.to_s)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ActiveStorage::PurgeJob }
    expect(jobs).not_to be_empty
    ActiveStorage::PurgeJob.perform_now(previous)
    expect(record.reload.image_count).to eq(2)
    expect(previous.reload.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.jpg")))
  end

  it "retains shared blobs and other attachments when deleting both own references" do
    save_images(1)
    image = record.reload.image_library.first
    profile = create(:profile, user: create(:user))
    profile.profile_image.attach(image.blob)
    UserOshis::Save.call(user_oshi: record, remove_image_id: image.id.to_s, clear_representative: true)
    ActiveStorage::PurgeJob.perform_now(image.blob)
    expect(record.reload.image_count).to eq(0)
    expect(profile.reload.profile_image.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.png")))
  end

  it "purges the original after its last reference is explicitly removed and jobs run" do
    save_images(1)
    image = record.reload.image_library.first
    blob = image.blob
    UserOshis::Save.call(user_oshi: record, remove_image_id: image.id.to_s, clear_representative: true)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).to include(ActiveStorage::PurgeJob)
    ActiveStorage::PurgeJob.perform_now(blob)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  end
end
