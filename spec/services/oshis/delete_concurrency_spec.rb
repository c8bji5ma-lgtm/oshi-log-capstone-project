require "rails_helper"
require "timeout"

RSpec.describe "Unused oshi deletion concurrency" do
  self.use_transactional_tests = false

  around do |example|
    raise "Local test database required" unless Rails.env.test? && User.connection.current_database == "my_app_test"

    @owned_user = create(:user)
    @owned_oshi = create(:oshi, :approved)
    example.run
  ensure
    UserOshi.where(oshi_id: @owned_oshi&.id, user_id: @owned_user&.id).delete_all if @owned_oshi && @owned_user
    Oshi.where(id: @owned_oshi.id).delete_all if @owned_oshi
    Profile.where(user_id: @owned_user.id).delete_all if @owned_user
    User.where(id: @owned_user.id).delete_all if @owned_user
  end

  def finish_threads(threads, release)
    release << true
    threads.each do |thread|
      thread.kill if thread.alive? && !thread.join(10)
      thread.join
    end
  end

  it "refuses deletion without waiting when a registration already holds the FK lock" do
    token = Oshis::Delete.confirmation(@owned_oshi)
    ready, release, results = Queue.new, Queue.new, Queue.new
    id, user_id = @owned_oshi.id, @owned_user.id
    threads = [ Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        UserOshi.transaction do
          UserOshi.create!(oshi_id: id, user_id: user_id)
          ready << true
          Timeout.timeout(10) { release.pop }
        end
        results << :registered
      rescue StandardError => error
        results << error
      end
    end ]
    Timeout.timeout(10) { ready.pop }
    expect { Oshis::Delete.call(id: id, confirmation: token) }.to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    expect(threads.first.join(10)).not_to be_nil
    expect(results.pop).to eq(:registered)
    expect(Oshi.exists?(id)).to be(true)
    expect(UserOshi.where(oshi_id: id, user_id: user_id).count).to eq(1)
  ensure
    finish_threads(threads || [], release || Queue.new)
  end

  it "blocks a new reference until deletion commits, then the FK rejects it without an orphan" do
    token = Oshis::Delete.confirmation(@owned_oshi)
    locked, release, backend_pid, results = Queue.new, Queue.new, Queue.new, Queue.new
    id, user_id = @owned_oshi.id, @owned_user.id
    allow_any_instance_of(Oshi).to receive(:destroy!).and_wrap_original do |method|
      locked << true
      Timeout.timeout(10) { release.pop }
      method.call
    end
    threads = [ Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Oshis::Delete.call(id: id, confirmation: token)
        results << :deleted
      rescue StandardError => error
        results << error
      end
    end ]
    Timeout.timeout(10) { locked.pop }
    threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend_pid << connection.select_value("SELECT pg_backend_pid()").to_i
        UserOshi.create!(oshi_id: id, user_id: user_id)
        results << :unexpected_registration
      rescue StandardError => error
        results << error.class
      end
    end
    pid = Timeout.timeout(10) { backend_pid.pop }
    Timeout.timeout(10) do
      loop do
        wait = ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        break if wait == "Lock"

        sleep 0.01
      end
    end
    release << true
    threads.each { |thread| expect(thread.join(10)).not_to be_nil }
    expect(Array.new(2) { results.pop }).to contain_exactly(:deleted, ActiveRecord::InvalidForeignKey)
    expect(Oshi.exists?(id)).to be(false)
    expect(UserOshi.where(oshi_id: id)).not_to exist
  ensure
    finish_threads(threads || [], release || Queue.new)
  end

  it "allows only one of two simultaneous deletions and safely handles a later repeat" do
    token = Oshis::Delete.confirmation(@owned_oshi)
    locked, release, results = Queue.new, Queue.new, Queue.new
    id = @owned_oshi.id
    allow_any_instance_of(Oshi).to receive(:destroy!).and_wrap_original do |method|
      locked << true
      Timeout.timeout(10) { release.pop }
      method.call
    end
    threads = [ Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Oshis::Delete.call(id: id, confirmation: token)
        results << :deleted
      rescue StandardError => error
        results << error
      end
    end ]
    Timeout.timeout(10) { locked.pop }
    expect { Oshis::Delete.call(id: id, confirmation: token) }.to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    expect(threads.first.join(10)).not_to be_nil
    expect(results.pop).to eq(:deleted)
    expect { Oshis::Delete.call(id: id, confirmation: token) }.to raise_error(ActiveRecord::RecordNotFound)
  ensure
    finish_threads(threads || [], release || Queue.new)
  end
end
