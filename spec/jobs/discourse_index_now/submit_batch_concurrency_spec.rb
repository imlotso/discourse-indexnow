# frozen_string_literal: true

require "rails_helper"
require "timeout"

describe Jobs::DiscourseIndexNow::SubmitBatch do
  self.use_transactional_tests = false

  let(:batch_id) { SecureRandom.uuid }

  before do
    SiteSetting.login_required = false
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    SiteSetting.indexnow_hourly_limit = 200
    SiteSetting.indexnow_daily_limit = 10_000
    Discourse.redis.del(DiscourseIndexNow::Throttle::THROTTLE_UNTIL_KEY)
    DiscourseIndexNow::Throttle.reset!
  end

  after do
    DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id).delete_all
    DiscourseIndexNow::Throttle.reset!
  end

  it "sends a queued record only once when two workers start together" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: "#{Discourse.base_url}/categories",
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
      trigger_reason: :manual,
    )
    calls = []
    mutex = Mutex.new
    allow(DiscourseIndexNow::Client).to receive(:submit_batch) do |urls|
      mutex.synchronize { calls << urls }
      sleep 0.2
      { success: true, status: 200 }
    end

    # The test pool has two connections; let both workers use them.
    ActiveRecord::Base.connection_pool.release_connection
    ready = Queue.new
    start = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.new.execute(batch_id: batch_id, batch_index: 1)
        end
      end
    end
    Timeout.timeout(15) do
      2.times { ready.pop }
      2.times { start << true }
      workers.each(&:value)
    end

    expect(calls).to eq([[log.url]])
    expect(log.reload).to be_success
    expect(DiscourseIndexNow::Throttle.hourly_used).to eq(1)
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
  end
end
