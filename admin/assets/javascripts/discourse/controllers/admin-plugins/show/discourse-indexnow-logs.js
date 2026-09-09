import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { duration } from "discourse/lib/formatter";
import { i18n } from "discourse-i18n";

const PER_PAGE = 50;
const TREND_DAY_WIDTH = 40;
const TREND_BAR_HEIGHT = 72;

export default class AdminPluginsShowDiscourseIndexNowLogsController extends Controller {
  @service dialog;

  @tracked data = null;
  @tracked status = "";
  @tracked url = "";
  @tracked batchId = "";
  @tracked page = 1;
  @tracked loading = false;
  @tracked backfillCategoryId = "";
  @tracked backfillSince = "";
  @tracked backfillUntil = "";
  @tracked backfillPreview = null;
  @tracked backfillResult = null;
  @tracked backfillLoading = false;
  @tracked manualUrls = "";
  @tracked manualResult = null;
  @tracked manualLoading = false;

  get logs() {
    return (this.data?.logs || []).map((log) => ({
      ...log,
      status_label: i18n(`discourse_index_now.admin.status_${log.status}`),
      trigger_reason_label: i18n(
        `discourse_index_now.admin.trigger_reason_${log.trigger_reason}`
      ),
    }));
  }

  get stats() {
    const stats = this.data?.stats || {};
    return {
      ...stats,
      categories: (stats.categories || []).map((category) => ({
        ...category,
        selected: String(category.id) === this.backfillCategoryId,
      })),
    };
  }

  get trendBars() {
    const trend = this.stats.trend_7d || [];
    const max = Math.max(1, ...trend.map((day) => day.success + day.failed));

    return trend.map((day, index) => {
      const centerX = 20 + index * TREND_DAY_WIDTH;
      const successHeight = Math.round((day.success / max) * TREND_BAR_HEIGHT);
      const failedHeight = Math.round((day.failed / max) * TREND_BAR_HEIGHT);
      const successY = 84 - successHeight;
      const failedY = 84 - failedHeight;

      return {
        ...day,
        short_date: day.date.slice(5),
        successX: centerX - 10,
        failedX: centerX + 2,
        labelX: centerX,
        successY,
        failedY,
        successHeight,
        failedHeight,
        edgeLabel: index === 0 || index === trend.length - 1,
      };
    });
  }

  get meta() {
    return this.data?.meta || {};
  }

  get failureBars() {
    const breakdown = this.stats.failure_breakdown || [];
    const max = Math.max(1, ...breakdown.map((item) => item.count));

    return breakdown.map((item) => ({
      ...item,
      label: i18n(
        `discourse_index_now.admin.failure_${item.category}`
      ),
      width: Math.max(2, Math.round((item.count / max) * 180)),
      style: trustHTML(
        `width: ${Math.max(2, Math.round((item.count / max) * 180))}px`
      ),
    }));
  }

  /**
   * The plugin's own submission caps, shaped for the quota bars.
   *
   * Both windows roll: the backend sums fine-grained buckets covering the last
   * hour and the last day, so there is no boundary to count down to and no
   * moment when a cap is handed back all at once. Capacity returns gradually,
   * as the oldest counted submissions age out.
   *
   * These are the plugin's own caps. IndexNow publishes no quota; its only
   * signal is the 429 surfaced by `throttledFor` below.
   */
  get quotas() {
    const usage = this.stats.usage || {};

    return [
      {
        key: "hourly",
        label: i18n("discourse_index_now.admin.quota_hourly"),
        used: usage.hourly_used || 0,
        limit: usage.hourly_limit || 0,
        freesIn: usage.hourly_frees_in,
      },
      {
        key: "daily",
        label: i18n("discourse_index_now.admin.quota_daily"),
        used: usage.daily_used || 0,
        limit: usage.daily_limit || 0,
        freesIn: usage.daily_frees_in,
      },
    ].map((quota) => this.buildQuotaBar(quota));
  }

  /**
   * One quota bar.
   *
   * A limit of 0 does not mean unlimited: Throttle#available_capacity returns 0
   * when either limit is <= 0, so nothing is submitted at all. Draw that as a
   * full bar and say why, rather than as an empty one that reads as idle.
   */
  buildQuotaBar(quota) {
    const blocked = quota.limit <= 0;
    const exhausted = blocked || quota.used >= quota.limit;
    const percent = blocked
      ? 100
      : Math.min(100, Math.round((quota.used / quota.limit) * 100));

    return {
      ...quota,
      blocked,
      exhausted,
      percent,
      style: trustHTML(`width: ${percent}%`),
      countLabel: blocked
        ? i18n("discourse_index_now.admin.quota_blocked")
        : i18n("discourse_index_now.admin.quota_count", {
            used: quota.used,
            limit: quota.limit,
          }),
      // Only worth saying once a cap is spent, and never for a limit of 0:
      // nothing ages out of a window that admits nothing, so there is no
      // countdown to offer -- an admin has to raise the setting.
      freesLabel:
        exhausted && !blocked && typeof quota.freesIn === "number"
          ? i18n("discourse_index_now.admin.quota_frees_in", {
              duration: duration(quota.freesIn),
            })
          : null,
    };
  }

  /** Set only while IndexNow itself has us backed off after answering 429. */
  get throttledFor() {
    const seconds = this.stats.usage?.throttled_for;

    return typeof seconds === "number" ? duration(seconds) : null;
  }

  get atFirstPage() {
    return this.page <= 1;
  }

  get atLastPage() {
    return this.page >= (this.meta.total_pages || 1);
  }

  @action
  async setStatus(value) {
    this.status = value;
    this.page = 1;
    await this.load();
  }

  @action
  async filterAll() {
    await this.setStatus("");
  }

  @action
  async filterPending() {
    await this.setStatus("pending");
  }

  @action
  async filterSuccess() {
    await this.setStatus("success");
  }

  @action
  async filterFailed() {
    await this.setStatus("failed");
  }

  @action
  async filterCancelled() {
    await this.setStatus("cancelled");
  }

  @action
  updateUrl(value) {
    this.url = value;
    this.page = 1;
  }

  @action
  updateBatchId(value) {
    this.batchId = value;
    this.page = 1;
  }

  @action
  async search() {
    this.page = 1;
    await this.load();
  }

  @action
  async previousPage() {
    if (this.atFirstPage) {
      return;
    }

    this.page -= 1;
    await this.load();
  }

  @action
  async nextPage() {
    if (this.atLastPage) {
      return;
    }

    this.page += 1;
    await this.load();
  }

  /**
   * Replacing a key is a legitimate thing to want, but it is destructive in a way
   * the button does not look, so it asks first.
   *
   * The old key stops working the moment this returns, and IndexNow validates
   * keys out of band: a submission whose key it has not yet re-fetched from
   * /<key>.txt comes back 202 ("key validation pending") rather than 200, and
   * those URLs are dropped if that validation then fails. So an accidental
   * rotation does not merely change a string, it can silently cost indexing until
   * search engines catch up.
   *
   * Nothing is at stake when no key is set yet, so that case skips the prompt.
   */
  @action
  generateKey() {
    if (!this.stats.api_key) {
      return this.rotateKey();
    }

    this.dialog.deleteConfirm({
      message: i18n("discourse_index_now.admin.generate_key_confirm"),
      confirmButtonLabel: "discourse_index_now.admin.generate_key_confirm_button",
      didConfirm: () => this.rotateKey(),
    });
  }

  async rotateKey() {
    try {
      this.loading = true;
      await ajax(
        "/admin/plugins/discourse-indexnow/generate_key.json",
        {
          type: "POST",
        }
      );
      this.batchId = "";
      this.page = 1;
      await this.load();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  async load() {
    this.loading = true;

    const data = {
      page: this.page,
      per_page: PER_PAGE,
    };

    Object.assign(data, this.logFilterParams);

    try {
      this.data = await ajax("/admin/plugins/discourse-indexnow/logs.json", {
        data,
      });
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  get logFilterParams() {
    const data = {};

    if (this.status) {
      data.status = this.status;
    }

    if (this.url) {
      data.url = this.url;
    }

    if (this.batchId) {
      data.batch_id = this.batchId;
    }

    return data;
  }

  @action
  setBackfillCategory(event) {
    this.backfillCategoryId = event.target.value;
  }

  @action
  setBackfillSince(value) {
    this.backfillSince = value ? value.format("YYYY-MM-DD") : "";
  }

  @action
  setBackfillUntil(value) {
    this.backfillUntil = value ? value.format("YYYY-MM-DD") : "";
  }

  get backfillParams() {
    const params = {};

    if (this.backfillCategoryId) {
      params.category_id = this.backfillCategoryId;
    }

    if (this.backfillSince) {
      params.since = this.backfillSince;
    }

    if (this.backfillUntil) {
      params.until = this.backfillUntil;
    }

    return params;
  }

  @action
  async previewBackfill() {
    this.backfillLoading = true;
    this.backfillResult = null;

    try {
      this.backfillPreview = await ajax(
        "/admin/plugins/discourse-indexnow/backfill/preview.json",
        {
          data: this.backfillParams,
        }
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.backfillLoading = false;
    }
  }

  @action
  async submitBackfill() {
    this.backfillLoading = true;

    try {
      this.backfillResult = await ajax(
        "/admin/plugins/discourse-indexnow/backfill.json",
        {
          type: "POST",
          data: this.backfillParams,
        }
      );
      this.batchId = this.backfillResult.batch_id;
      this.page = 1;
      await this.load();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.backfillLoading = false;
    }
  }

  @action
  updateManualUrls(event) {
    this.manualUrls = event.target.value;
  }

  @action
  async submitManualUrls() {
    this.manualLoading = true;

    try {
      this.manualResult = await ajax(
        "/admin/plugins/discourse-indexnow/submit_urls.json",
        {
          type: "POST",
          data: { urls: this.manualUrls },
        }
      );
      this.batchId = this.manualResult.batch_id;
      this.page = 1;
      await this.load();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.manualLoading = false;
    }
  }

  @action
  cancelPending() {
    this.dialog.confirm({
      message: i18n("discourse_index_now.admin.cancel_pending_confirm"),
      didConfirm: () => this.destroyLogs("cancel"),
    });
  }

  @action
  deleteLogs() {
    this.dialog.deleteConfirm({
      message: i18n("discourse_index_now.admin.delete_logs_confirm"),
      didConfirm: () => this.destroyLogs("delete"),
    });
  }

  async destroyLogs(operation) {
    this.loading = true;

    try {
      if (operation === "cancel") {
        await ajax("/admin/plugins/discourse-indexnow/cancel_pending.json", {
          type: "POST",
          data: this.logFilterParams,
        });
      } else {
        await ajax("/admin/plugins/discourse-indexnow/logs.json", {
          type: "DELETE",
          data: this.logFilterParams,
        });
      }

      this.page = 1;
      await this.load();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }
}
