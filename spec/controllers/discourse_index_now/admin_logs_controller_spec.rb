# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::AdminLogsController, type: :request do
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }

  before do
    SiteSetting.indexnow_enabled = true
    SiteSetting.login_required = false
    SiteSetting.indexnow_api_key = "a" * 32
    SiteSetting.indexnow_excluded_tag_names = ""
    allow(DiscourseIndexNow::KeyAccessibility).to receive(:check).and_return(true)
    sign_in(admin)
  end

  describe "#index" do
    it "returns batch-aware logs, pagination metadata, and stats" do
      DiscourseIndexNow::SubmissionLog.create!(
        url: "https://forum.example.com/t/one/1",
        batch_id: "batch-1",
        batch_index: 1,
        locale: nil,
        status: :success,
      )
      DiscourseIndexNow::SubmissionLog.create!(
        url: "https://forum.example.com/t/one/1?tl=es",
        batch_id: "batch-1",
        batch_index: 1,
        locale: "es",
        status: :failed,
        error_message: "HTTP 429",
      )

      get "/admin/plugins/discourse-indexnow/logs.json", params: { page: 1, per_page: 1 }

      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["logs"].size).to eq(1)
      expect(json["logs"].first["trigger_reason"]).to eq("created")
      expect(json["meta"]["total_count"]).to eq(2)
      expect(json["stats"]["key_accessible"]).to eq(true)
    end

    # The admin page draws its quota bars from these numbers; without them it
    # renders two empty bars that read as "nothing submitted yet".
    it "includes the throttle counters the quota bars are drawn from" do
      DiscourseIndexNow::Throttle.record_submission!(5)

      get "/admin/plugins/discourse-indexnow/logs.json"

      usage = response.parsed_body["stats"]["usage"]
      expect(usage["hourly_used"]).to eq(5)
      expect(usage["daily_used"]).to eq(5)
      expect(usage["hourly_limit"]).to eq(SiteSetting.indexnow_hourly_limit)
      expect(usage["daily_limit"]).to eq(SiteSetting.indexnow_daily_limit)
      expect(usage["hourly_window"]).to eq(3600)
      expect(usage["daily_window"]).to eq(86_400)
    end

    it "returns a pending state without waiting for a cold-cache probe" do
      allow(DiscourseIndexNow::KeyAccessibility).to receive(:check).and_return(nil)

      get "/admin/plugins/discourse-indexnow/logs.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["stats"]).to include(
        "key_accessible" => nil,
        "key_accessibility_pending" => true,
        "key_accessibility_status" => "pending",
      )
    end

    it "filters by status, URL, and batch id" do
      DiscourseIndexNow::SubmissionLog.create!(
        url: "https://forum.example.com/t/one/1",
        batch_id: "batch-1",
        status: :success,
      )
      DiscourseIndexNow::SubmissionLog.create!(
        url: "https://forum.example.com/t/two/2",
        batch_id: "batch-2",
        status: :failed,
      )

      get "/admin/plugins/discourse-indexnow/logs.json",
          params: {
            status: "success",
            url: "one",
            batch_id: "batch-1",
          }

      json = response.parsed_body
      expect(json["logs"].map { |log| log["status"] }).to eq(["success"])
      expect(json["logs"].map { |log| log["url"] }).to all(include("one"))
    end

    it "returns a seven day trend and failure breakdown" do
      freeze_time(2.days.ago) do
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/a/1",
          status: :success,
        )
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/b/2",
          status: :failed,
          error_message: "HTTP 429",
        )
      end
      DiscourseIndexNow::SubmissionLog.create!(
        url: "https://forum.example.com/t/c/3",
        status: :failed,
        response_code: 403,
        error_message: "key error",
      )

      get "/admin/plugins/discourse-indexnow/logs.json"

      stats = response.parsed_body["stats"]
      trend = stats["trend_7d"].find { |day| day["date"] == 2.days.ago.to_date.to_s }
      expect(trend["success"]).to eq(1)
      expect(trend["failed"]).to eq(1)

      breakdown = stats["failure_breakdown"]
      rate_limit = breakdown.find { |item| item["category"] == "rate_limit" }
      key_error = breakdown.find { |item| item["category"] == "key_error" }
      expect(rate_limit["count"]).to eq(1)
      expect(key_error["count"]).to eq(1)
    end
  end

  describe "#generate_key" do
    it "generates a new key without storing rotation state" do
      post "/admin/plugins/discourse-indexnow/generate_key.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["api_key"]).to match(/\A[a-f0-9]{32}\z/)
      expect(SiteSetting.indexnow_api_key).to eq(response.parsed_body["api_key"])
      expect(PluginStore.get(DiscourseIndexNow::PLUGIN_NAME, "previous_api_key")).to be_nil
      expect(PluginStore.get(DiscourseIndexNow::PLUGIN_NAME, "previous_key_expires_at")).to be_nil
    end
  end

  describe "#cancel_pending" do
    it "cancels only pending logs matching the current filters" do
      pending_log =
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/one/1",
          batch_id: "batch-1",
          status: :pending,
        )
      failed_log =
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/one/1?tl=es",
          locale: "es",
          batch_id: "batch-1",
          status: :failed,
          error_message: "HTTP 429",
        )
      other_batch_log =
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/two/2",
          batch_id: "batch-2",
          status: :pending,
        )

      post "/admin/plugins/discourse-indexnow/cancel_pending.json",
           params: {
             batch_id: "batch-1",
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["cancelled_count"]).to eq(1)
      expect(pending_log.reload).to be_cancelled
      expect(pending_log.error_message).to eq("cancelled_by_admin")
      expect(failed_log.reload).to be_failed
      expect(other_batch_log.reload).to be_pending
    end

    it "does not cancel logs when the status filter excludes pending logs" do
      log =
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/one/1",
          status: :pending,
        )

      post "/admin/plugins/discourse-indexnow/cancel_pending.json",
           params: {
             status: "success",
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["cancelled_count"]).to eq(0)
      expect(log.reload).to be_pending
    end
  end

  describe "#destroy_filtered" do
    it "deletes only logs matching the current filters" do
      retained =
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/one/1",
          batch_id: "batch-1",
          status: :success,
        )
      deleted =
        DiscourseIndexNow::SubmissionLog.create!(
          url: "https://forum.example.com/t/two/2",
          batch_id: "batch-2",
          status: :failed,
        )

      delete "/admin/plugins/discourse-indexnow/logs.json",
             params: {
               status: "failed",
             }

      expect(response.status).to eq(200)
      expect(response.parsed_body["deleted_count"]).to eq(1)
      expect(DiscourseIndexNow::SubmissionLog.exists?(deleted.id)).to be(false)
      expect(retained.reload).to be_success
    end
  end

  describe "#backfill_preview" do
    it "previews eligible topics and localized URLs without submitting" do
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)
      SiteSetting.indexnow_enabled = false
      localization = Fabricate(:topic_localization, topic: topic, locale: "es")
      SiteSetting.indexnow_enabled = true

      get "/admin/plugins/discourse-indexnow/backfill/preview.json",
          params: {
            category_id: category.id,
          }

      json = response.parsed_body
      expect(json["matched_topics"]).to eq(1)
      expect(json["url_count"]).to eq(2)
      expect(json["urls"]).to eq([topic.url, "#{topic.url}?tl=es"])
      expect(DiscourseIndexNow::SubmissionLog.count).to eq(0)
    end

    it "excludes restricted categories" do
      restricted = Fabricate(:category, read_restricted: true)
      restricted_topic = Fabricate(:topic, category: restricted)

      get "/admin/plugins/discourse-indexnow/backfill/preview.json"

      json = response.parsed_body
      expect(json["matched_topics"]).to eq(1)
      expect(json["urls"]).not_to include(restricted_topic.url)
    end

    it "excludes topics carrying an excluded tag" do
      excluded_tag = Fabricate(:tag, name: "internal")
      topic.tags << excluded_tag
      SiteSetting.indexnow_excluded_tag_names = "internal"

      get "/admin/plugins/discourse-indexnow/backfill/preview.json"

      json = response.parsed_body
      expect(json["matched_topics"]).to eq(0)
      expect(json["urls"]).not_to include(topic.url)
    end
  end

  describe "#backfill" do
    it "submits the selected URLs through the generic batch service" do
      allow(DiscourseIndexNow::SubmissionService).to receive(:enqueue_batch).with(
        [{ url: topic.url, locale: nil }],
        source: "backfill",
        trigger_reason: :backfill,
      ).and_return(batch_id: "batch-1", submitted_count: 1, job_count: 1, source: "backfill")

      post "/admin/plugins/discourse-indexnow/backfill.json",
           params: {
             category_id: category.id,
             since: 1.year.ago.to_date.to_s,
             until: Date.today.to_s,
           }

      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["matched_topics"]).to eq(1)
      expect(json["submitted_urls"]).to eq(1)
      expect(json["batch_id"]).to eq("batch-1")
      expect(DiscourseIndexNow::SubmissionService).to have_received(:enqueue_batch).with(
        [{ url: topic.url, locale: nil }],
        source: "backfill",
        trigger_reason: :backfill,
      )
    end
  end

  describe "#submit_urls" do
    it "submits valid on-site topic URLs through the generic batch service" do
      allow(DiscourseIndexNow::SubmissionService).to receive(:enqueue_batch).with(
        [{ url: topic.url, locale: nil }],
        source: "manual",
        trigger_reason: :manual,
      ).and_return(batch_id: "batch-manual-1", submitted_count: 1, job_count: 1, source: "manual")

      post "/admin/plugins/discourse-indexnow/submit_urls.json", params: { urls: topic.url }

      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["submitted_urls"]).to eq(1)
      expect(json["batch_id"]).to eq("batch-manual-1")
      expect(DiscourseIndexNow::SubmissionService).to have_received(:enqueue_batch).with(
        [{ url: topic.url, locale: nil }],
        source: "manual",
        trigger_reason: :manual,
      )
    end

    it "rejects external, invalid, and ineligible topic URLs" do
      restricted = Fabricate(:category, read_restricted: true)
      restricted_topic = Fabricate(:topic, category: restricted)
      external_url = "https://example.org/t/topic/999"
      invalid_url = "not-a-url"

      post "/admin/plugins/discourse-indexnow/submit_urls.json",
           params: {
             urls: [external_url, invalid_url, restricted_topic.url].join("\n"),
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "rejects empty input explicitly" do
      post "/admin/plugins/discourse-indexnow/submit_urls.json", params: { urls: "\n" }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "rejects more URLs than IndexNow allows in one request" do
      urls =
        Array.new(DiscourseIndexNow::SubmissionService::BATCH_SIZE + 1) { topic.url }.join("\n")
      post "/admin/plugins/discourse-indexnow/submit_urls.json", params: { urls: urls }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "deduplicates repeated URLs while preserving order" do
      allow(DiscourseIndexNow::SubmissionService).to receive(:enqueue_batch).with(
        [{ url: topic.url, locale: nil }],
        source: "manual",
        trigger_reason: :manual,
      ).and_return(batch_id: "batch-manual-2", submitted_count: 1, job_count: 1, source: "manual")

      post "/admin/plugins/discourse-indexnow/submit_urls.json",
           params: {
             urls: [topic.url, topic.url].join("\n"),
           }

      expect(response.status).to eq(200)
      expect(DiscourseIndexNow::SubmissionService).to have_received(:enqueue_batch).with(
        [{ url: topic.url, locale: nil }],
        source: "manual",
        trigger_reason: :manual,
      )
    end

    it "submits on-site non-topic URLs" do
      url = "#{Discourse.base_url}/categories"
      allow(DiscourseIndexNow::SubmissionService).to receive(:enqueue_batch).with(
        [{ url: url, locale: nil }],
        source: "manual",
        trigger_reason: :manual,
      ).and_return(batch_id: "batch-manual-3", submitted_count: 1, job_count: 1, source: "manual")

      post "/admin/plugins/discourse-indexnow/submit_urls.json", params: { urls: url }

      expect(response.status).to eq(200)
      expect(DiscourseIndexNow::SubmissionService).to have_received(:enqueue_batch).with(
        [{ url: url, locale: nil }],
        source: "manual",
        trigger_reason: :manual,
      )
    end
  end
end
