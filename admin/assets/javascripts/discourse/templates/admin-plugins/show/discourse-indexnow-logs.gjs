import { on } from "@ember/modifier";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DDateInput from "discourse/ui-kit/d-date-input";
import DExpandingTextArea from "discourse/ui-kit/d-expanding-text-area";
import DTextField from "discourse/ui-kit/d-text-field";
import dAgeWithTooltip from "discourse/ui-kit/helpers/d-age-with-tooltip";
import { i18n } from "discourse-i18n";

export default <template>
  <div class="indexnow-admin">
    {{#if @controller.stats.login_required}}
      <div class="alert alert-error">
        {{i18n "discourse_index_now.admin.login_required_disabled"}}
      </div>
    {{/if}}

    <section class="indexnow-summary">
      <div>
        <strong>{{i18n "discourse_index_now.admin.enabled"}}:</strong>
        {{#if @controller.stats.enabled}}
          {{i18n "discourse_index_now.admin.yes"}}
        {{else}}
          {{i18n "discourse_index_now.admin.no"}}
        {{/if}}
      </div>

      <div>
        <strong>{{i18n "discourse_index_now.admin.api_key"}}:</strong>
        <code>{{@controller.stats.api_key}}</code>
      </div>

      <div class="indexnow-key-status">
        <strong>{{i18n "discourse_index_now.admin.key_accessible"}}:</strong>
        <span class="indexnow-key-dot indexnow-key-{{@controller.stats.key_accessibility_status}}"></span>
        {{#if @controller.stats.key_accessibility_pending}}
          {{i18n "discourse_index_now.admin.pending"}}
        {{else if @controller.stats.key_accessible}}
          {{i18n "discourse_index_now.admin.yes"}}
        {{else}}
          {{i18n "discourse_index_now.admin.no"}}
        {{/if}}
      </div>

      <div>
        <strong>{{i18n "discourse_index_now.admin.today_success"}}:</strong>
        {{@controller.stats.today_success_count}}
      </div>

      <div>
        <strong>{{i18n "discourse_index_now.admin.today_failed"}}:</strong>
        {{@controller.stats.today_failed_count}}
      </div>

      <DButton
        @label="discourse_index_now.admin.generate_key"
        @action={{@controller.generateKey}}
        @disabled={{@controller.loading}}
      />
    </section>

    <section class="indexnow-quotas">
      <h3>{{i18n "discourse_index_now.admin.quota_title"}}</h3>

      {{#if @controller.throttledFor}}
        <div class="alert alert-warning indexnow-quota-throttled">
          {{i18n
            "discourse_index_now.admin.quota_throttled"
            duration=@controller.throttledFor
          }}
        </div>
      {{/if}}

      <div class="indexnow-quota-grid">
        {{#each @controller.quotas as |quota|}}
          <div class="indexnow-quota">
            <div class="indexnow-quota-header">
              <span>{{quota.label}}</span>
              <span class="indexnow-quota-count">{{quota.countLabel}}</span>
            </div>
            <div
              class="indexnow-quota-track"
              role="progressbar"
              aria-label={{quota.label}}
              aria-valuemin="0"
              aria-valuemax="100"
              aria-valuenow={{quota.percent}}
              aria-valuetext={{quota.countLabel}}
            >
              <span
                class="indexnow-quota-bar {{if quota.exhausted "indexnow-quota-bar--exhausted"}}"
                style={{quota.style}}
              ></span>
            </div>
            {{#if quota.freesLabel}}
              <div class="indexnow-quota-frees">{{quota.freesLabel}}</div>
            {{/if}}
          </div>
        {{/each}}
      </div>
    </section>

    <section class="indexnow-charts">
      <div class="indexnow-chart">
        <h3>{{i18n "discourse_index_now.admin.trend_7d"}}</h3>
        <svg
          class="indexnow-trend-svg"
          viewBox="0 0 280 112"
          preserveAspectRatio="xMidYMid meet"
          role="img"
          aria-label={{i18n "discourse_index_now.admin.trend_7d"}}
        >
          {{#each @controller.trendBars as |day|}}
            <rect
              x={{day.successX}}
              y={{day.successY}}
              width="8"
              height={{day.successHeight}}
              class="indexnow-bar-success"
            />
            <rect x={{day.failedX}} y={{day.failedY}} width="8" height={{day.failedHeight}} class="indexnow-bar-failed" />
            <text
              x={{day.labelX}}
              y="101"
              text-anchor="middle"
              class="indexnow-trend-label {{if day.edgeLabel "" "indexnow-trend-label--middle"}}"
            >{{day.short_date}}</text>
          {{/each}}
        </svg>
        <div class="indexnow-chart-legend">
          <span class="indexnow-bar-success"></span>
          {{i18n "discourse_index_now.admin.status_success"}}
          <span class="indexnow-bar-failed"></span>
          {{i18n "discourse_index_now.admin.status_failed"}}
        </div>
      </div>

      <div class="indexnow-chart">
        <h3>{{i18n "discourse_index_now.admin.failure_breakdown"}}</h3>
        {{#each @controller.failureBars as |failure|}}
          <div class="indexnow-failure-row">
            <span>{{failure.label}}</span>
            <span class="indexnow-failure-count">{{failure.count}} ({{failure.percentage}}%)</span>
            <div class="indexnow-failure-track">
              <span class="indexnow-failure-bar" style={{failure.style}}></span>
            </div>
          </div>
        {{/each}}
      </div>
    </section>

    <section class="indexnow-backfill">
      <h3>{{i18n "discourse_index_now.admin.backfill"}}</h3>
      <div class="indexnow-backfill-controls">
        <select {{on "change" @controller.setBackfillCategory}}>
          <option value="">{{i18n "discourse_index_now.admin.all_categories"}}</option>
          {{#each @controller.stats.categories as |category|}}
            <option value={{category.id}} selected={{category.selected}}>
              {{category.name}}
            </option>
          {{/each}}
        </select>

        <DDateInput
          @date={{@controller.backfillSince}}
          @onChange={{@controller.setBackfillSince}}
        />
        <DDateInput
          @date={{@controller.backfillUntil}}
          @onChange={{@controller.setBackfillUntil}}
        />

        <DButton
          @label="discourse_index_now.admin.preview"
          @action={{@controller.previewBackfill}}
          @disabled={{@controller.backfillLoading}}
        />
        <DButton
          @label="discourse_index_now.admin.submit_backfill"
          @action={{@controller.submitBackfill}}
          @disabled={{@controller.backfillLoading}}
        />
      </div>

      {{#if @controller.backfillPreview}}
        <div class="indexnow-backfill-result">
          {{i18n
            "discourse_index_now.admin.backfill_preview"
            topics=@controller.backfillPreview.matched_topics
            urls=@controller.backfillPreview.url_count
          }}
        </div>
      {{/if}}

      {{#if @controller.backfillResult}}
        <div class="indexnow-backfill-result">
          {{i18n
            "discourse_index_now.admin.backfill_result"
            topics=@controller.backfillResult.matched_topics
            urls=@controller.backfillResult.submitted_urls
            batch_id=@controller.backfillResult.batch_id
          }}
        </div>
      {{/if}}
    </section>

    <section class="indexnow-manual">
      <h3>{{i18n "discourse_index_now.admin.manual_submission"}}</h3>
      <DExpandingTextArea
        @value={{@controller.manualUrls}}
        @input={{@controller.updateManualUrls}}
        placeholder={{i18n "discourse_index_now.admin.manual_urls_placeholder"}}
        rows="4"
      />
      <div class="indexnow-manual-controls">
        <DButton
          @label="discourse_index_now.admin.submit_manual"
          @action={{@controller.submitManualUrls}}
          @disabled={{@controller.manualLoading}}
        />
      </div>
      {{#if @controller.manualResult}}
        <div class="indexnow-manual-result">
          {{i18n
            "discourse_index_now.admin.manual_result"
            urls=@controller.manualResult.submitted_urls
            batch_id=@controller.manualResult.batch_id
          }}
        </div>
      {{/if}}
    </section>

    <section class="indexnow-controls">
      <div class="indexnow-status-filters">
        <DButton
          @label="discourse_index_now.admin.filter_all"
          @action={{@controller.filterAll}}
        />
        <DButton
          @label="discourse_index_now.admin.filter_pending"
          @action={{@controller.filterPending}}
        />
        <DButton
          @label="discourse_index_now.admin.filter_success"
          @action={{@controller.filterSuccess}}
        />
        <DButton
          @label="discourse_index_now.admin.filter_failed"
          @action={{@controller.filterFailed}}
        />
        <DButton
          @label="discourse_index_now.admin.filter_cancelled"
          @action={{@controller.filterCancelled}}
        />
      </div>

      <div class="indexnow-url-search">
        <DTextField
          @value={{@controller.url}}
          @placeholderKey="discourse_index_now.admin.url_placeholder"
          @onChange={{@controller.updateUrl}}
        />
        <DTextField
          @value={{@controller.batchId}}
          @placeholderKey="discourse_index_now.admin.batch_placeholder"
          @onChange={{@controller.updateBatchId}}
        />
        <DButton
          @label="discourse_index_now.admin.search"
          @action={{@controller.search}}
          @disabled={{@controller.loading}}
        />
        <DButton
          @label="discourse_index_now.admin.cancel_pending"
          @action={{@controller.cancelPending}}
          @disabled={{@controller.loading}}
        />
        <DButton
          @label="discourse_index_now.admin.delete_logs"
          @action={{@controller.deleteLogs}}
          @disabled={{@controller.loading}}
        />
      </div>
    </section>

    <DConditionalLoadingSpinner @condition={{@controller.loading}} />

    <table class="d-admin-table indexnow-log-table">
      <thead>
        <tr>
          <th>{{i18n "discourse_index_now.admin.url"}}</th>
          <th>{{i18n "discourse_index_now.admin.locale"}}</th>
          <th>{{i18n "discourse_index_now.admin.status"}}</th>
          <th>{{i18n "discourse_index_now.admin.trigger_reason"}}</th>
          <th>{{i18n "discourse_index_now.admin.response_code"}}</th>
          <th>{{i18n "discourse_index_now.admin.error_message"}}</th>
          <th>{{i18n "discourse_index_now.admin.batch"}}</th>
          <th>{{i18n "discourse_index_now.admin.created_at"}}</th>
        </tr>
      </thead>
      <tbody>
        {{#each @controller.logs as |entry|}}
          <tr>
            <td>{{entry.url}}</td>
            <td>{{if entry.locale entry.locale "-"}}</td>
            <td class="indexnow-status-{{entry.status}}">{{entry.status_label}}</td>
            <td>{{entry.trigger_reason_label}}</td>
            <td>{{entry.response_code}}</td>
            <td>{{entry.error_message}}</td>
            <td><code>{{entry.batch_id}}</code></td>
            <td>{{dAgeWithTooltip entry.created_at}}</td>
          </tr>
        {{else}}
          <tr>
            <td colspan="8">{{i18n "discourse_index_now.admin.no_logs"}}</td>
          </tr>
        {{/each}}
      </tbody>
    </table>

    <div class="indexnow-pagination">
      <DButton
        @label="discourse_index_now.admin.previous_page"
        @action={{@controller.previousPage}}
        @disabled={{@controller.atFirstPage}}
      />
      <span>
        {{i18n
          "discourse_index_now.admin.page_info"
          page=@controller.page
          total_pages=@controller.meta.total_pages
        }}
      </span>
      <DButton
        @label="discourse_index_now.admin.next_page"
        @action={{@controller.nextPage}}
        @disabled={{@controller.atLastPage}}
      />
    </div>
  </div>
</template>
