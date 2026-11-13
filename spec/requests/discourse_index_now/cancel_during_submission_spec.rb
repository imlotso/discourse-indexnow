# frozen_string_literal: true

require "rails_helper"

describe "IndexNow cancellation during a submission", type: :request do
  fab!(:admin)
  fab!(:topic)
  let(:batch_id) { SecureRandom.uuid }

  before do
    SiteSetting.login_required = false
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    SiteSetting.indexnow_hourly_limit = 200
    SiteSetting.indexnow_daily_limit = 10_000
    Discourse.redis.del(DiscourseIndexNow::Throttle::THROTTLE_UNTIL_KEY)
    DiscourseIndexNow::Throttle.reset!
    allow(Jobs).to receive(:enqueue_in)
    sign_in(admin)
  end

  [true, false].each do |tracked_batch|
    it "does not retry an in-flight failure after cancelling #{tracked_batch ? 'a tracked' : 'a legacy'} batch" do
      if tracked_batch
        DiscourseIndexNow::Batch.create!(batch_id: batch_id, kind: "backfill", status: "generated")
      end
      log = DiscourseIndexNow::SubmissionLog.create!(
        url: topic.url,
        topic_id: topic.id,
        batch_id: batch_id,
        batch_index: 1,
        status: :pending,
      )
      allow(DiscourseIndexNow::Client).to receive(:submit_batch) do
        post "/admin/plugins/discourse-indexnow/cancel_pending.json", params: { batch_id: batch_id }
        expect(response.status).to eq(200)
        { success: false, status: 429, error: "HTTP 429", retry_after: 60 }
      end

      Jobs::DiscourseIndexNow::SubmitBatch.new.execute(batch_id: batch_id, batch_index: 1)

      expect(log.reload).to be_cancelled
      expect(Jobs).not_to have_received(:enqueue_in)
      expect(DiscourseIndexNow::Batch.find_by!(batch_id: batch_id).status).to eq("cancelled") if tracked_batch
    end
  end

  it "does not send a claimed URL when cancellation arrives before the request" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      topic_id: topic.id,
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
    )
    allow(DiscourseIndexNow::Throttle).to receive(:reserve!) do
      post "/admin/plugins/discourse-indexnow/cancel_pending.json", params: { batch_id: batch_id }
      1
    end
    allow(DiscourseIndexNow::Client).to receive(:submit_batch)

    Jobs::DiscourseIndexNow::SubmitBatch.new.execute(batch_id: batch_id, batch_index: 1)

    expect(DiscourseIndexNow::Client).not_to have_received(:submit_batch)
    expect(log.reload).to be_cancelled
  end

  it "records a successful response to a request that was already sent" do
    log = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      topic_id: topic.id,
      batch_id: batch_id,
      batch_index: 1,
      status: :pending,
    )
    allow(DiscourseIndexNow::Client).to receive(:submit_batch) do
      post "/admin/plugins/discourse-indexnow/cancel_pending.json", params: { batch_id: batch_id }
      { success: true, status: 200 }
    end

    Jobs::DiscourseIndexNow::SubmitBatch.new.execute(batch_id: batch_id, batch_index: 1)

    expect(log.reload).to be_success
    expect(log.response_code).to eq(200)
    expect(Jobs).not_to have_received(:enqueue_in)
  end
end
