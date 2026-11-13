import { fn } from "@ember/helper";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DDateInput from "discourse/ui-kit/d-date-input";
import DExpandingTextArea from "discourse/ui-kit/d-expanding-text-area";
import DNativeSelect from "discourse/ui-kit/d-native-select";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import DTextField from "discourse/ui-kit/d-text-field";
import dAgeWithTooltip from "discourse/ui-kit/helpers/d-age-with-tooltip";
import { i18n } from "discourse-i18n";

export default <template>
  <div class="indexnow-admin">
    <DPageSubheader
      @descriptionLabel={{i18n "discourse_index_now.admin.logs_description"}}
      @titleLabel={{i18n "discourse_index_now.admin.logs"}}
    />
    <p class="indexnow-indexing-note">{{i18n
        "discourse_index_now.admin.indexing_note"
      }}</p>
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
        <span
          class="indexnow-key-dot indexnow-key-{{@controller.stats.key_accessibility_status}}"
        ></span>
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
        @action={{@controller.generateKey}}
        @disabled={{@controller.loading}}
        @label="discourse_index_now.admin.generate_key"
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
              aria-label={{quota.label}}
              aria-valuemax="100"
              aria-valuemin="0"
              aria-valuenow={{quota.percent}}
              aria-valuetext={{quota.countLabel}}
              class="indexnow-quota-track"
              role="progressbar"
            >
              <span
                class="indexnow-quota-bar
                  {{if quota.exhausted 'indexnow-quota-bar--exhausted'}}"
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
          aria-label={{i18n "discourse_index_now.admin.trend_7d"}}
          class="indexnow-trend-svg"
          preserveAspectRatio="xMidYMid meet"
          role="img"
          viewBox="0 0 280 112"
        >
          {{#each @controller.trendBars as |day|}}
            <rect
              class="indexnow-bar-success"
              height={{day.successHeight}}
              width="8"
              x={{day.successX}}
              y={{day.successY}}
            />
            <rect
              class="indexnow-bar-failed"
              height={{day.failedHeight}}
              width="8"
              x={{day.failedX}}
              y={{day.failedY}}
            />
            <text
              class="indexnow-trend-label
                {{if day.edgeLabel '' 'indexnow-trend-label--middle'}}"
              text-anchor="middle"
              x={{day.labelX}}
              y="101"
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
            <span class="indexnow-failure-count">{{failure.count}}
              ({{failure.percentage}}%)</span>
            <div class="indexnow-failure-track">
              <span class="indexnow-failure-bar" style={{failure.style}}></span>
            </div>
          </div>
        {{/each}}
      </div>
    </section>

    <section class="indexnow-backfill">
      <h3>{{i18n "discourse_index_now.admin.backfill"}}</h3>
      {{#if @controller.stats.time_zone}}
        <p>{{i18n
            "discourse_index_now.admin.date_timezone"
            timezone=@controller.stats.time_zone
          }}</p>
      {{/if}}
      <div class="indexnow-backfill-controls">
        <div class="indexnow-field">
          <label for="indexnow-backfill-category">{{i18n
              "discourse_index_now.admin.category"
            }}</label>
          <DNativeSelect
            id="indexnow-backfill-category"
            @nonePlaceholder={{i18n "discourse_index_now.admin.all_categories"}}
            @onChange={{@controller.setBackfillCategory}}
            @value={{@controller.backfillCategoryId}}
            as |select|
          >
            {{#each @controller.stats.categories as |category|}}
              <select.Option @value={{category.id}}>
                {{category.name}}
              </select.Option>
            {{/each}}
          </DNativeSelect>
        </div>

        <div class="indexnow-field">
          <label for="indexnow-backfill-since">{{i18n
              "discourse_index_now.admin.date_since"
            }}</label>
          <DDateInput
            id="indexnow-backfill-since"
            @date={{@controller.backfillSince}}
            @onChange={{@controller.setBackfillSince}}
          />
        </div>
        <div class="indexnow-field">
          <label for="indexnow-backfill-until">{{i18n
              "discourse_index_now.admin.date_until"
            }}</label>
          <DDateInput
            id="indexnow-backfill-until"
            @date={{@controller.backfillUntil}}
            @onChange={{@controller.setBackfillUntil}}
          />
        </div>

        <DButton
          @action={{@controller.previewBackfill}}
          @disabled={{@controller.backfillLoading}}
          @label="discourse_index_now.admin.preview"
        />
        <DButton
          class="indexnow-submit-backfill"
          @action={{@controller.submitBackfill}}
          @disabled={{@controller.backfillLoading}}
          @label="discourse_index_now.admin.submit_backfill"
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

    </section>

    {{#if @controller.batchProgress}}
      <section aria-live="polite" class="indexnow-batch-progress">
        <strong>{{i18n "discourse_index_now.admin.batch"}}:</strong>
        <code>{{@controller.batchProgress.batch_id}}</code>
        <p>{{@controller.batchProgressLabel}}</p>
        {{#if @controller.batchProgress.retry_at}}
          <p>{{i18n "discourse_index_now.admin.retry_at"}}
            {{dAgeWithTooltip @controller.batchProgress.retry_at}}</p>
        {{/if}}
        {{#if @controller.batchProgress.error_message}}
          <p
            class="alert alert-error"
          >{{@controller.batchProgress.error_message}}</p>
        {{/if}}
        <DButton
          @action={{@controller.refreshBatch}}
          @label="discourse_index_now.admin.refresh_progress"
        />
      </section>
    {{/if}}

    <section class="indexnow-manual">
      <h3>{{i18n "discourse_index_now.admin.manual_submission"}}</h3>
      <label for="indexnow-manual-urls">{{i18n
          "discourse_index_now.admin.manual_urls_placeholder"
        }}</label>
      <DExpandingTextArea
        id="indexnow-manual-urls"
        placeholder={{i18n "discourse_index_now.admin.manual_urls_placeholder"}}
        rows="4"
        @input={{@controller.updateManualUrls}}
        @value={{@controller.manualUrls}}
      />
      <div class="indexnow-manual-controls">
        <DButton
          @action={{@controller.submitManualUrls}}
          @disabled={{@controller.manualLoading}}
          @label="discourse_index_now.admin.submit_manual"
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
        {{#each @controller.statusFilters as |filter|}}
          <DButton
            class={{if filter.selected "btn-primary" ""}}
            @action={{fn @controller.setStatus filter.value}}
            @ariaPressed={{filter.selected}}
            @label={{filter.label}}
          />
        {{/each}}
      </div>

      <div class="indexnow-url-search">
        <div class="indexnow-field">
          <label for="indexnow-filter-url">{{i18n
              "discourse_index_now.admin.url"
            }}</label>
          <DTextField
            id="indexnow-filter-url"
            @onChange={{@controller.updateUrl}}
            @placeholderKey="discourse_index_now.admin.url_placeholder"
            @value={{@controller.url}}
          />
        </div>
        <div class="indexnow-field">
          <label for="indexnow-filter-batch">{{i18n
              "discourse_index_now.admin.batch"
            }}</label>
          <DTextField
            id="indexnow-filter-batch"
            @onChange={{@controller.updateBatchId}}
            @placeholderKey="discourse_index_now.admin.batch_placeholder"
            @value={{@controller.batchId}}
          />
          <DButton
            class="indexnow-view-batch"
            @action={{@controller.viewBatchProgress}}
            @disabled={{@controller.batchIdEmpty}}
            @label="discourse_index_now.admin.view_batch_progress"
          />
        </div>
        <div class="indexnow-field">
          <label for="indexnow-filter-trigger">{{i18n
              "discourse_index_now.admin.trigger_reason"
            }}</label>
          <DNativeSelect
            id="indexnow-filter-trigger"
            @nonePlaceholder={{i18n "discourse_index_now.admin.filter_all"}}
            @onChange={{@controller.setTriggerReason}}
            @value={{@controller.triggerReason}}
            as |select|
          >
            {{#each @controller.triggerOptions as |option|}}
              <select.Option
                @value={{option.value}}
              >{{option.label}}</select.Option>
            {{/each}}
          </DNativeSelect>
        </div>
        <div class="indexnow-field">
          <label for="indexnow-filter-response">{{i18n
              "discourse_index_now.admin.response_code"
            }}</label>
          <DTextField
            id="indexnow-filter-response"
            @onChange={{@controller.setResponseCode}}
            @value={{@controller.responseCode}}
          />
        </div>
        <div class="indexnow-field">
          <label for="indexnow-filter-locale">{{i18n
              "discourse_index_now.admin.locale"
            }}</label>
          <DTextField
            id="indexnow-filter-locale"
            @onChange={{@controller.setLogLocale}}
            @value={{@controller.logLocale}}
          />
        </div>
        <div class="indexnow-field">
          <label for="indexnow-filter-since">{{i18n
              "discourse_index_now.admin.date_since"
            }}</label>
          <DDateInput
            id="indexnow-filter-since"
            @date={{@controller.logSince}}
            @onChange={{@controller.setLogSince}}
          />
        </div>
        <div class="indexnow-field">
          <label for="indexnow-filter-until">{{i18n
              "discourse_index_now.admin.date_until"
            }}</label>
          <DDateInput
            id="indexnow-filter-until"
            @date={{@controller.logUntil}}
            @onChange={{@controller.setLogUntil}}
          />
        </div>
        <DButton
          class="indexnow-search-button"
          @action={{@controller.search}}
          @disabled={{@controller.loading}}
          @label="discourse_index_now.admin.search"
        />
        <DButton
          class="indexnow-retry-filtered"
          @action={{@controller.retryFailed}}
          @disabled={{@controller.retryLoading}}
          @label="discourse_index_now.admin.retry_filtered"
        />
        <DButton
          @action={{@controller.cancelPending}}
          @disabled={{@controller.loading}}
          @label="discourse_index_now.admin.cancel_pending"
        />
        <DButton
          @action={{@controller.deleteLogs}}
          @disabled={{@controller.loading}}
          @label="discourse_index_now.admin.delete_logs"
        />
      </div>
    </section>

    <DConditionalLoadingSpinner @condition={{@controller.loading}} />

    <table class="d-table indexnow-log-table">
      <thead class="d-table__header">
        <tr class="d-table__row">
          <th>{{i18n "discourse_index_now.admin.url"}}</th>
          <th>{{i18n "discourse_index_now.admin.locale"}}</th>
          <th>{{i18n "discourse_index_now.admin.status"}}</th>
          <th>{{i18n "discourse_index_now.admin.trigger_reason"}}</th>
          <th>{{i18n "discourse_index_now.admin.response_code"}}</th>
          <th>{{i18n "discourse_index_now.admin.error_message"}}</th>
          <th>{{i18n "discourse_index_now.admin.batch"}}</th>
          <th>{{i18n "discourse_index_now.admin.created_at"}}</th>
          <th>{{i18n "discourse_index_now.admin.actions"}}</th>
        </tr>
      </thead>
      <tbody class="d-table__body">
        {{#each @controller.logs as |entry|}}
          <tr class="d-table__row">
            <td class="d-table__cell --overview">{{entry.url}}</td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n "discourse_index_now.admin.locale"}}</div>{{if
                entry.locale
                entry.locale
                "-"
              }}</td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n "discourse_index_now.admin.status"}}</div><span
                class="indexnow-status-{{entry.status}}"
              >{{entry.status_label}}</span></td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n
                  "discourse_index_now.admin.trigger_reason"
                }}</div>{{entry.trigger_reason_label}}</td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n
                  "discourse_index_now.admin.response_code"
                }}</div>{{entry.response_code}}</td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n
                  "discourse_index_now.admin.error_message"
                }}</div>{{entry.error_message}}</td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n "discourse_index_now.admin.batch"}}</div><code
              >{{entry.batch_id}}</code></td>
            <td class="d-table__cell --detail"><div
                class="d-table__mobile-label"
              >{{i18n
                  "discourse_index_now.admin.created_at"
                }}</div>{{dAgeWithTooltip entry.created_at}}</td>
            <td class="d-table__cell --controls">
              {{#if entry.can_retry}}
                <DButton
                  class="indexnow-retry-one"
                  @action={{fn @controller.retryOne entry.id}}
                  @disabled={{@controller.retryLoading}}
                  @label="discourse_index_now.admin.retry_one"
                />
              {{/if}}
            </td>
          </tr>
        {{else}}
          <tr>
            <td colspan="9">{{i18n "discourse_index_now.admin.no_logs"}}</td>
          </tr>
        {{/each}}
      </tbody>
    </table>

    <div class="indexnow-pagination">
      <DButton
        @action={{@controller.previousPage}}
        @disabled={{@controller.atFirstPage}}
        @label="discourse_index_now.admin.previous_page"
      />
      <span>
        {{i18n
          "discourse_index_now.admin.page_info"
          page=@controller.page
          total_pages=@controller.meta.total_pages
        }}
      </span>
      <DButton
        @action={{@controller.nextPage}}
        @disabled={{@controller.atLastPage}}
        @label="discourse_index_now.admin.next_page"
      />
    </div>
  </div>
</template>
