# frozen_string_literal: true

require "rails_helper"

describe "IndexNow asynchronous backfill", type: :request do
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

  it "returns a batch immediately and generates topic logs in the background" do
    post "/admin/plugins/discourse-indexnow/backfill_async.json", params: { category_id: category.id }

    expect(response.status).to eq(202)
    batch_id = response.parsed_body["batch_id"]
    expect(DiscourseIndexNow::SubmissionLog.count).to eq(0)

    Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)

    log = DiscourseIndexNow::SubmissionLog.find_by!(url: topic.url)
    expect(log.topic_id).to eq(topic.id)
    expect(log.batch_id).to eq(batch_id)

    get "/admin/plugins/discourse-indexnow/batches/#{batch_id}.json"
    expect(response.parsed_body["queued_count"]).to eq(1)
    expect(response.parsed_body["status"]).to eq("running")

    log.update!(status: :success, response_code: 200)
    get "/admin/plugins/discourse-indexnow/batches/#{batch_id}.json"
    expect(response.parsed_body["status"]).to eq("completed")
    expect(response.parsed_body["status_counts"]).to include("success" => 1)
  end

  it "generates more than one full-sized chunk and reports its progress" do
    now = Time.zone.now
    rows = Array.new(Jobs::DiscourseIndexNow::GenerateBatch::CHUNK_SIZE + 1) do |index|
      {
        title: "Backfill topic #{index}",
        slug: "backfill-topic-#{index}",
        category_id: category.id,
        user_id: admin.id,
        last_post_user_id: admin.id,
        bumped_at: now,
        created_at: now,
        updated_at: now,
      }
    end
    Topic.insert_all!(rows)

    post "/admin/plugins/discourse-indexnow/backfill_async.json", params: { category_id: category.id }
    batch_id = response.parsed_body["batch_id"]
    expect(response.status).to eq(202)
    expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id)).to be_empty

    Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)

    get "/admin/plugins/discourse-indexnow/batches/#{batch_id}.json"
    expect(response.parsed_body).to include(
      "matched_count" => rows.size,
      "processed_count" => rows.size,
      "queued_count" => rows.size,
      "skipped_count" => 0,
      "status" => "running",
    )
    expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id).distinct.pluck(:batch_index)).to contain_exactly(1, 2)
  end

  it "does not generate work after a batch is cancelled" do
    post "/admin/plugins/discourse-indexnow/backfill_async.json", params: { category_id: category.id }
    batch_id = response.parsed_body["batch_id"]
    post "/admin/plugins/discourse-indexnow/cancel_pending.json", params: { batch_id: batch_id }

    Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)

    expect(DiscourseIndexNow::SubmissionLog.count).to eq(0)
    expect(DiscourseIndexNow::Batch.find_by!(batch_id: batch_id).status).to eq("cancelled")
  end

  it "counts a topic that becomes restricted before generation as skipped" do
    post "/admin/plugins/discourse-indexnow/backfill_async.json", params: { category_id: category.id }
    batch_id = response.parsed_body["batch_id"]
    category.update!(read_restricted: true)

    Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)

    batch = DiscourseIndexNow::Batch.find_by!(batch_id: batch_id)
    expect(batch.skipped_count).to eq(1)
    expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id)).to be_empty
  end

  it "resumes from its checkpoint after a transient enqueue failure" do
    another = Fabricate(:topic, category: category)
    post "/admin/plugins/discourse-indexnow/backfill_async.json", params: { category_id: category.id }
    batch_id = response.parsed_body["batch_id"]
    fail_once = true
    allow(Jobs).to receive(:enqueue) do |job, **_args|
      if job == Jobs::DiscourseIndexNow::SubmitBatch && fail_once
        fail_once = false
        raise "temporary queue failure"
      end
    end
    allow(Jobs).to receive(:enqueue_in)

    stub_const(Jobs::DiscourseIndexNow::GenerateBatch, :CHUNK_SIZE, 1) do
      expect { Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id) }.not_to raise_error
      batch = DiscourseIndexNow::Batch.find_by!(batch_id: batch_id)
      expect(batch.status).to eq("running")
      expect(batch.generation_attempt_count).to eq(1)
      expect(Jobs).to have_received(:enqueue_in)
      expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id).count).to eq(1)

      freeze_time(batch.retry_at + 1.second) do
        Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id)
      end

      expect(batch.reload.status).to eq("generated")
      expect(DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id).pluck(:topic_id)).to contain_exactly(topic.id, another.id)
    end
  end

  it "marks generation failed after the retry budget is exhausted" do
    post "/admin/plugins/discourse-indexnow/backfill_async.json", params: { category_id: category.id }
    batch_id = response.parsed_body["batch_id"]
    batch = DiscourseIndexNow::Batch.find_by!(batch_id: batch_id)
    batch.update!(status: "running", generation_attempt_count: 5)
    DiscourseIndexNow::SubmissionLog.create!(url: topic.url, topic_id: topic.id, batch_id: batch_id, batch_index: 1)
    allow(Jobs).to receive(:enqueue) { raise "queue unavailable" }
    allow(Jobs).to receive(:enqueue_in)

    expect { Jobs::DiscourseIndexNow::GenerateBatch.new.execute(batch_id: batch_id) }.not_to raise_error

    expect(batch.reload.status).to eq("failed")
    expect(batch.generation_attempt_count).to eq(6)
    expect(Jobs).not_to have_received(:enqueue_in)
  end
end
