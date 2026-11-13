import { click, fillIn, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

acceptance("IndexNow admin logs", function (needs) {
  needs.user();
  needs.settings({ indexnow_enabled: true });

  let lastLogsRequest;
  let backfillRequested;
  let retryRequest;
  let successResponseCode;

  needs.hooks.beforeEach(() => {
    lastLogsRequest = null;
    backfillRequested = false;
    retryRequest = null;
    successResponseCode = 202;
  });

  needs.pretender((server, helper) => {
    server.get("/admin/plugins/discourse-indexnow.json", () =>
      helper.response({
        id: "discourse-indexnow",
        name: "discourse-indexnow",
        enabled: true,
        has_settings: true,
        humanized_name: "IndexNow",
        admin_route: {
          label: "discourse_index_now.admin.title",
          location: "discourse-indexnow",
          use_new_show_route: true,
        },
      })
    );
    server.get("/admin/plugins/discourse-indexnow/logs.json", (request) => {
      lastLogsRequest = request;
      return helper.response({
        logs: [
          {
            id: 1,
            url: "https://example.com/t/one/1",
            status: "success",
            response_code: successResponseCode,
            trigger_reason: "created",
            created_at: "2026-01-01T00:00:00Z",
          },
          {
            id: 2,
            url: "https://example.com/t/two/2",
            status: "failed",
            response_code: 403,
            trigger_reason: "edited",
            created_at: "2026-01-01T00:00:00Z",
          },
        ],
        meta: { total_pages: 1 },
        stats: {
          categories: [],
          usage: {},
          trend_7d: [],
          failure_breakdown: [],
        },
      });
    });
    server.post("/admin/plugins/discourse-indexnow/backfill_async.json", () => {
      backfillRequested = true;
      return helper.response({ batch_id: "test-batch", status: "queued" });
    });
    server.post("/admin/plugins/discourse-indexnow/submit_urls.json", () =>
      helper.response({ batch_id: "manual-batch", submitted_urls: 1 })
    );
    server.post(
      "/admin/plugins/discourse-indexnow/retry_failed.json",
      (request) => {
        retryRequest = request;
        return helper.response({ batch_id: "test-batch", status: "queued" });
      }
    );
    server.get(
      "/admin/plugins/discourse-indexnow/batches/test-batch.json",
      () =>
        helper.response({
          batch_id: "test-batch",
          status: "completed",
          matched_count: 1,
          processed_count: 1,
          queued_count: 1,
          skipped_count: 0,
        })
    );
  });

  test("explains a 202 response without claiming it was indexed", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    assert
      .dom(".indexnow-status-success")
      .hasText("Received; key validation was pending");
    assert
      .dom(".indexnow-indexing-note")
      .includesText("does not guarantee crawling or indexing");
  });

  test("shows a 200 response as received without claiming it was indexed", async function (assert) {
    successResponseCode = 200;
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");

    assert.dom(".indexnow-status-success").hasText("Received");
    assert
      .dom(".indexnow-indexing-note")
      .includesText("does not guarantee crawling or indexing");
  });

  test("sends additional filters and starts backfill asynchronously", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    await fillIn("#indexnow-filter-response", "403");
    await click(".indexnow-search-button");
    assert.strictEqual(lastLogsRequest.queryParams.response_code, "403");

    await click(".indexnow-submit-backfill");
    assert.true(backfillRequested);
    assert.dom(".indexnow-batch-progress").exists();
  });

  test("confirms and retries one failed record", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    await click(".indexnow-retry-one");
    assert.strictEqual(retryRequest, null);
    await click(".dialog-footer .btn-primary");

    const body = new URLSearchParams(retryRequest.requestBody);
    assert.strictEqual(body.get("log_ids[]"), "2");
    assert.dom(".indexnow-batch-progress").exists();
  });

  test("retries failures using the active filters", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    await fillIn("#indexnow-filter-response", "403");
    await click(".indexnow-search-button");
    await click(".indexnow-retry-filtered");
    assert.strictEqual(retryRequest, null);
    await click(".dialog-footer .btn-primary");

    const body = new URLSearchParams(retryRequest.requestBody);
    assert.strictEqual(body.get("response_code"), "403");
    assert.strictEqual(body.get("log_ids[]"), null);
  });

  test("looks up batch progress after returning to the page", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    await fillIn("#indexnow-filter-batch", "test-batch");
    await click(".indexnow-view-batch");

    assert.dom(".indexnow-batch-progress").includesText("test-batch");
  });

  test("reloads the displayed filters when returning to the logs page", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    await fillIn("#indexnow-filter-url", "example.com/t/one");
    await click(".indexnow-search-button");
    await visit("/");
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");

    assert.dom("#indexnow-filter-url").hasValue("example.com/t/one");
    assert.strictEqual(lastLogsRequest.queryParams.url, "example.com/t/one");
  });

  test("shows a new manual batch without unrelated log filters", async function (assert) {
    await visit("/admin/plugins/discourse-indexnow/indexnow-logs");
    await fillIn("#indexnow-filter-url", "old-topic");
    await fillIn("#indexnow-filter-response", "403");
    await click(".indexnow-search-button");
    await fillIn("#indexnow-manual-urls", "https://example.com/categories");
    await click(".indexnow-manual-controls button");

    assert.strictEqual(lastLogsRequest.queryParams.batch_id, "manual-batch");
    assert.strictEqual(lastLogsRequest.queryParams.url, undefined);
    assert.strictEqual(lastLogsRequest.queryParams.response_code, undefined);
    assert.dom("#indexnow-filter-url").hasValue("");
    assert.dom("#indexnow-filter-response").hasValue("");
  });
});
