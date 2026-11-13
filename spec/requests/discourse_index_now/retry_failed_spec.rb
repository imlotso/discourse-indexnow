# frozen_string_literal: true

require "rails_helper"

describe "IndexNow manual retry", type: :request do
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }

  before do
    SiteSetting.login_required = false
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    allow(Jobs).to receive(:enqueue)
    sign_in(admin)
  end

  it "preserves a failed log and creates a new retry with its topic identity" do
    original = DiscourseIndexNow::SubmissionLog.create!(
      url: topic.url,
      topic_id: topic.id,
      status: :failed,
      trigger_reason: :edited,
      response_code: 403,
    )

    post "/admin/plugins/discourse-indexnow/retry_failed.json", params: { log_ids: [original.id] }
    expect(response.status).to eq(202)
    batch_id = response.parsed_body["batch_id"]
    Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)

    retry_log = DiscourseIndexNow::SubmissionLog.find_by!(batch_id: batch_id)
    expect(original.reload).to be_failed
    expect(retry_log.retry_of_id).to eq(original.id)
    expect(retry_log.topic_id).to eq(topic.id)
    expect(retry_log.trigger_reason).to eq("edited")
    expect(retry_log).to be_pending
  end

  it "skips topics that became restricted before the retry" do
    original = DiscourseIndexNow::SubmissionLog.create!(url: topic.url, topic_id: topic.id, status: :failed)
    category.update!(read_restricted: true)

    post "/admin/plugins/discourse-indexnow/retry_failed.json", params: { log_ids: [original.id] }
    batch_id = response.parsed_body["batch_id"]
    Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)

    expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id)).to be_empty
    expect(DiscourseIndexNow::Batch.find_by!(batch_id: batch_id).skipped_count).to eq(1)
  end

  it "rejects invalid identifiers without scheduling a wider retry" do
    post "/admin/plugins/discourse-indexnow/retry_failed.json", params: { log_ids: ["invalid"] }

    expect(response.status).to eq(400)
    expect(DiscourseIndexNow::Batch.count).to eq(0)
  end

  it "does not allow a non-admin to retry failures" do
    sign_in(Fabricate(:user))
    post "/admin/plugins/discourse-indexnow/retry_failed.json"

    expect(response.status).to satisfy { |status| [403, 404].include?(status) }
    expect(DiscourseIndexNow::Batch.count).to eq(0)
  end
end
