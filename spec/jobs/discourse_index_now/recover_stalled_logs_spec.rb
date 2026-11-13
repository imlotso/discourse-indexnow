# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseIndexNow::RecoverStalledLogs, type: :job do
  fab!(:topic)
  let(:batch_id) { SecureRandom.uuid }

  before do
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    allow(Jobs).to receive(:enqueue)
    allow(Jobs).to receive(:scheduled_for).and_return([])
    allow(Sidekiq::RetrySet).to receive(:new).and_return([])
    allow(Sidekiq::Queue).to receive(:new).and_return([])
    allow(Sidekiq::Workers).to receive(:new).and_return([])
  end

  it "re-enqueues stalled pending batches" do
    log =
      DiscourseIndexNow::SubmissionLog.create!(
        url: topic.url,
        batch_id: batch_id,
        batch_index: 1,
        status: :pending,
        created_at: 31.minutes.ago,
      )

    described_class.new.execute

    expect(Jobs).to have_received(:enqueue).with(
      Jobs::DiscourseIndexNow::SubmitBatch,
      batch_id: batch_id,
      batch_index: 1,
    )
    expect(log.reload).to be_pending
  end

  it "does not re-enqueue recent pending batches" do
    DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
    )

    described_class.new.execute

    expect(Jobs).not_to have_received(:enqueue)
  end

  it "recovers a processing claim after its lease expires" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      topic_id: topic.id,
      batch_id: batch_id,
      batch_index: 1,
      status: :processing,
      claim_token: "abandoned",
      claimed_at: 6.minutes.ago,
      created_at: 1.minute.ago,
    )

    described_class.new.execute

    expect(log.reload).to be_pending
    expect(log.claim_token).to be_nil
    expect(Jobs).to have_received(:enqueue).with(
      Jobs::DiscourseIndexNow::SubmitBatch,
      batch_id: batch_id,
      batch_index: 1,
    )
  end

  it "does not recover a retry before its scheduled time" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :retrying,
      available_at: 1.hour.from_now,
      created_at: 31.minutes.ago,
    )

    described_class.new.execute

    expect(log.reload).to be_retrying
    expect(Jobs).not_to have_received(:enqueue)
  end

  it "does not reclaim a stale-looking batch that is still executing" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :processing,
      claim_token: "active",
      claimed_at: 6.minutes.ago,
    )
    worker = ["process", "thread", { "payload" => { "class" => "Jobs::DiscourseIndexNow::SubmitBatch", "args" => [{ "batch_id" => batch_id, "batch_index" => 1 }] } }]
    allow(Sidekiq::Workers).to receive(:new).and_return([worker])

    described_class.new.execute

    expect(log.reload).to be_processing
    expect(Jobs).not_to have_received(:enqueue)
  end

  it "cancels an abandoned claim when cancellation was requested" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :processing,
      claim_token: "abandoned",
      claimed_at: 6.minutes.ago,
      cancel_requested: true,
    )

    described_class.new.execute

    expect(log.reload).to be_cancelled
    expect(Jobs).not_to have_received(:enqueue)
  end

  it "does not re-enqueue a batch that is scheduled for a later attempt" do
    DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
      created_at: 31.minutes.ago,
    )

    allow(Jobs).to receive(:scheduled_for).and_return([instance_double(Sidekiq::ScheduledSet)])

    described_class.new.execute

    expect(Jobs).not_to have_received(:enqueue)
  end

  it "does not re-enqueue a batch that is waiting in Sidekiq retry" do
    DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
      created_at: 31.minutes.ago,
    )

    retry_job = Struct.new(:klass, :args).new(
      "Jobs::DiscourseIndexNow::SubmitBatch",
      [{ "batch_id" => batch_id, "batch_index" => 1 }],
    )
    allow(Sidekiq::RetrySet).to receive(:new).and_return([retry_job])

    described_class.new.execute

    expect(Jobs).not_to have_received(:enqueue)
  end

  it "does not re-enqueue cancelled batches" do
    DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :cancelled,
      error_message: "cancelled_by_admin",
      created_at: 31.minutes.ago,
    )

    described_class.new.execute

    expect(Jobs).not_to have_received(:enqueue)
  end

  it "recovers an interrupted background batch generation" do
    batch = DiscourseIndexNow::Batch.create!(batch_id: batch_id, kind: "backfill", status: "running")
    batch.update_columns(updated_at: 31.minutes.ago)
    SiteSetting.indexnow_hourly_limit = 0

    described_class.new.execute

    expect(Jobs).to have_received(:enqueue).with(
      Jobs::DiscourseIndexNow::GenerateBatch,
      batch_id: batch_id,
    )
  end

  it "does nothing when the plugin is disabled" do
    SiteSetting.indexnow_enabled = false
    DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
      created_at: 31.minutes.ago,
    )

    described_class.new.execute

    expect(Jobs).not_to have_received(:enqueue)
  end
end
