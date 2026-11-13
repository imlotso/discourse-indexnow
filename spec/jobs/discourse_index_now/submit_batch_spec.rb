# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseIndexNow::SubmitBatch do
  fab!(:topic)
  let(:batch_id) { SecureRandom.uuid }
  let!(:logs) do
    [
      DiscourseIndexNow::SubmissionLog.create!(
        url: topic.url,
        batch_id: batch_id,
        batch_index: 1,
        status: :pending,
      ),
      DiscourseIndexNow::SubmissionLog.create!(
        url: "#{topic.url}?tl=es",
        locale: "es",
        batch_id: batch_id,
        batch_index: 1,
        status: :pending,
      ),
    ]
  end

  before do
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    SiteSetting.indexnow_hourly_limit = 200
    SiteSetting.indexnow_daily_limit = 10_000
    Discourse.redis.del(DiscourseIndexNow::Throttle::THROTTLE_UNTIL_KEY)
    DiscourseIndexNow::Throttle.reset!
  end

  after do
    Discourse.redis.del(DiscourseIndexNow::Throttle::THROTTLE_UNTIL_KEY)
    DiscourseIndexNow::Throttle.reset!
  end

  it "submits all URLs in a batch and marks each log successful" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: true,
      status: 202,
    )

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).to have_received(:submit_batch).with(
      [topic.url, "#{topic.url}?tl=es"],
    )
    logs.each { |log| expect(log.reload).to be_success }
    expect(logs.first.response_code).to eq(202)
  end

  it "does not submit cancelled logs" do
    logs.each { |log| log.update!(status: :cancelled, error_message: "cancelled_by_admin") }

    allow(DiscourseIndexNow::Client).to receive(:submit_batch)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    logs.each { |log| expect(log.reload).to be_cancelled }
  end

  it "schedules a retry after a rate-limited batch submission" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 429,
      error: "HTTP 429",
    )

    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    logs.each { |log| expect(log.reload).to be_retrying }
    expect(logs.first.error_message).to eq("HTTP 429")
    expect(logs.first.attempt_count).to eq(1)
    expect(Jobs).to have_received(:enqueue_in)
  end

  it "sets the throttle when IndexNow returns Retry-After" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 429,
      error: "HTTP 429",
      retry_after: 120,
    )

    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Throttle).to be_throttled
  end

  it "marks a permanent HTTP error failed without scheduling a retry" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 403,
      error: "HTTP 403",
    )
    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(logs.map { |log| log.reload.status }).to eq(%w[failed failed])
    expect(Jobs).not_to have_received(:enqueue_in)
  end

  it "retries an HTTP request timeout" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 408,
      error: "HTTP 408",
    )
    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(logs.map { |log| log.reload.status }).to eq(%w[retrying retrying])
    expect(Jobs).to have_received(:enqueue_in)
  end

  it "marks a transient failure final after five retries" do
    logs.each { |log| log.update!(attempt_count: 5) }
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 503,
      error: "HTTP 503",
    )
    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(logs.map { |log| log.reload.status }).to eq(%w[failed failed])
    expect(Jobs).not_to have_received(:enqueue_in)
  end

  it "does not reschedule indefinitely when a configured limit is zero" do
    SiteSetting.indexnow_hourly_limit = 0
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)
    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(Jobs).not_to have_received(:enqueue_in)
    expect(logs.map { |log| log.reload.status }).to eq(%w[pending pending])
  end

  it "submits only the remaining capacity and reschedules the rest" do
    DiscourseIndexNow::Throttle.record_submission!(199)
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: true,
      status: 202,
    )
    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).to have_received(:submit_batch).with(
      [topic.url],
    )
    expect(Jobs).to have_received(:enqueue_in)
    expect(logs.first.reload).to be_success
    expect(logs.second.reload).to be_pending
  end

  it "reschedules without submitting when no capacity remains" do
    DiscourseIndexNow::Throttle.record_submission!(200)
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)
    allow(Jobs).to receive(:enqueue_in)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(Jobs).to have_received(:enqueue_in)
    logs.each { |log| expect(log.reload).to be_pending }
  end

  it "eventually submits a backfill larger than the hourly capacity" do
    SiteSetting.indexnow_hourly_limit = 2
    backfill_batch_id = SecureRandom.uuid
    backfill_logs =
      Array.new(5) do |index|
        DiscourseIndexNow::SubmissionLog.create!(
          url: "#{topic.url}?page=#{index + 1}",
          batch_id: backfill_batch_id,
          batch_index: 1,
          status: :pending,
        )
      end

    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: true,
      status: 202,
    )
    allow(Jobs).to receive(:enqueue_in)

    5.times do
      described_class.new.execute(batch_id: backfill_batch_id, batch_index: 1)
      break if backfill_logs.none? { |log| log.reload.pending? }

      DiscourseIndexNow::Throttle.reset!
    end

    expect(DiscourseIndexNow::Client).to have_received(:submit_batch).at_least(3).times
    backfill_logs.each { |log| expect(log.reload).to be_success }
  end

  it "continues a batch after the current worker's bounded claim" do
    stub_const(described_class, :CLAIM_LIMIT, 2) do
      extra = DiscourseIndexNow::SubmissionLog.create!(
        url: "#{topic.url}?page=2",
        topic_id: topic.id,
        batch_id: batch_id,
        batch_index: 1,
        status: :pending,
      )
      allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(success: true, status: 200)
      allow(Jobs).to receive(:enqueue_in)

      described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)
      expect(Jobs).to have_received(:enqueue_in)
      expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id, status: :pending).count).to eq(1)

      described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)
      expect((logs + [extra]).map { |log| log.reload.status }).to eq(%w[success success success])
    end
  end

  it "fails the batch when the topic becomes ineligible" do
    SiteSetting.indexnow_excluded_category_ids = topic.category_id.to_s
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    logs.each { |log| expect(log.reload.error_message).to eq("ineligible_at_execution") }
  end

  it "rechecks topic eligibility for a legacy backfill without a topic id" do
    SiteSetting.indexnow_excluded_category_ids = topic.category_id.to_s
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(success: true, status: 200)

    described_class.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(logs.map { |log| log.reload.status }).to eq(%w[failed failed])
  end

  it "does not retry records invalidated by a category restriction" do
    logs.each { |log| log.update!(status: :failed, error_message: "category_restricted") }
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(success: true, status: 200)

    described_class.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(logs.map { |log| log.reload.error_message }).to eq(%w[category_restricted category_restricted])
  end

  it "does not send records already claimed by another worker" do
    logs.each { |log| log.update!(status: :processing, claim_token: "other", claimed_at: Time.zone.now) }
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)

    described_class.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(logs.map { |log| log.reload.status }).to eq(%w[processing processing])
  end

  it "checks each topic in a mixed batch independently" do
    restricted_category = Fabricate(:category, read_restricted: true)
    restricted_topic = Fabricate(:topic, category: restricted_category)
    logs.first.update!(topic_id: topic.id)
    logs.second.update!(url: restricted_topic.url, topic_id: restricted_topic.id)
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(success: true, status: 200)

    described_class.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).to have_received(:submit_batch).with([topic.url])
    expect(logs.first.reload).to be_success
    expect(logs.second.reload).to be_failed
  end

  it "rejects a URL whose topic does not match its stored identity" do
    restricted_topic = Fabricate(:topic, category: Fabricate(:category, read_restricted: true))
    logs.each { |log| log.update!(url: restricted_topic.url, topic_id: topic.id) }
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)

    described_class.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(logs.map { |log| log.reload.status }).to eq(%w[failed failed])
  end

  it "submits a deletion notice for a previously public topic" do
    topic.update!(deleted_at: Time.zone.now)
    logs.each { |log| log.update!(topic_id: topic.id, trigger_reason: :deleted) }
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(success: true, status: 200)

    described_class.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).to have_received(:submit_batch).once
    expect(logs.map { |log| log.reload.status }).to eq(%w[success success])
  end
end
