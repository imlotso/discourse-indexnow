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

  it "marks logs failed and raises after a failed batch submission" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 429,
      error: "HTTP 429",
    )

    expect {
      described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)
    }.to raise_error(DiscourseIndexNow::Client::SubmissionError)

    logs.each { |log| expect(log.reload).to be_failed }
    expect(logs.first.error_message).to eq("HTTP 429")
  end

  it "sets the throttle when IndexNow returns Retry-After" do
    allow(DiscourseIndexNow::Client).to receive(:submit_batch).and_return(
      success: false,
      status: 429,
      error: "HTTP 429",
      retry_after: 120,
    )

    expect {
      described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)
    }.to raise_error(DiscourseIndexNow::Client::SubmissionError)

    expect(DiscourseIndexNow::Throttle).to be_throttled
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

  it "fails the batch when the topic becomes ineligible" do
    SiteSetting.indexnow_excluded_category_ids = topic.category_id.to_s
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)

    described_class.new.execute(batch_id: batch_id, batch_index: 1, topic_id: topic.id)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    logs.each { |log| expect(log.reload.error_message).to eq("ineligible_at_execution") }
  end
end
