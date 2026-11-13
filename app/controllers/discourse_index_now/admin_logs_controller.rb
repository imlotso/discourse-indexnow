# frozen_string_literal: true

require "securerandom"
require "uri"

module DiscourseIndexNow
  class AdminLogsController < ::Admin::AdminController
    requires_plugin DiscourseIndexNow::PLUGIN_NAME

    def index
      page = [params[:page].to_i, 1].max
      per_page = [[params[:per_page].to_i, 1].max, 50].min

      scope = filtered_logs.order(created_at: :desc)

      total_count = scope.count
      logs = scope.limit(per_page).offset((page - 1) * per_page)

      render json: {
               logs: logs.map { |log| serialize_log(log) },
               meta: {
                 page: page,
                 per_page: per_page,
                 total_count: total_count,
                 total_pages: [total_count.fdiv(per_page).ceil, 1].max,
               },
               stats: stats,
             }
    end

    def cancel_pending
      filter = LogFilter.new(params)
      values = filter.to_h.with_indifferent_access
      cancel_batch = values[:batch_id].present? && values.except(:batch_id, :status).empty? &&
        (values[:status].blank? || %w[pending retrying].include?(values[:status]))
      cancelled_count = 0
      Batch.transaction do
        if cancel_batch
          batch = Batch.lock.find_by(batch_id: values[:batch_id])
          cancellable = batch && (
            %w[queued running].include?(batch.status) ||
              (batch.status == "generated" && filter.apply.where(status: %i[pending retrying processing]).exists?)
          )
          batch.update!(status: "cancelled") if cancellable
        end
        # A request already in flight may finish, but it must not schedule a
        # further attempt. Update all three active states in one statement so a
        # worker cannot move between states between separate cancellation queries.
        cancelled_count = filter.apply.where(status: %i[pending retrying processing], cancel_requested: false).update_all(
          [
            "status = CASE WHEN status = ? THEN status ELSE ? END, " \
              "cancel_requested = TRUE, " \
              "error_message = CASE WHEN status = ? THEN error_message ELSE ? END, updated_at = ?",
            SubmissionLog.statuses[:processing],
            SubmissionLog.statuses[:cancelled],
            SubmissionLog.statuses[:processing],
            "cancelled_by_admin",
            Time.zone.now,
          ],
        )
      end

      render json: { cancelled_count: cancelled_count }
    end

    def destroy_filtered
      deleted_count = filtered_logs.delete_all

      render json: { deleted_count: deleted_count }
    end

    def generate_key
      SiteSetting.indexnow_api_key = SecureRandom.hex(16)
      render json: {
               api_key: SiteSetting.indexnow_api_key,
             }
    end

    def backfill_preview
      topics = backfill_topics
      matched_count = topics.count
      locale_count = 0
      if ::ContentLocalization.crawler_locale_param_enabled?
        localized = TopicLocalization.where(topic_id: topics.reorder(nil).select(:id)).where.not(locale: nil).select(:topic_id, :locale).distinct
        locale_count = TopicLocalization.unscoped.from(localized, :indexnow_localizations).count
      end
      entries = topics.limit(100).flat_map { |topic| UrlBuilder.build_urls(topic) }.first(100)

      render json: {
               matched_topics: matched_count,
               url_count: matched_count + locale_count,
               urls: entries.map { |entry| entry[:url] },
             }
    end

    def backfill
      topics = backfill_topics
      entries = topics.flat_map { |topic| UrlBuilder.build_urls(topic).map { |entry| entry.merge(topic_id: topic.id) } }
      result =
        SubmissionService.enqueue_batch(
          entries,
          source: "backfill",
          trigger_reason: :backfill,
        )

      render json: {
               matched_topics: topics.size,
               submitted_urls: result[:submitted_count],
               batch_id: result[:batch_id],
             }
    end

    def backfill_async
      query = BackfillQuery.new(params)
      topics = query.scope
      batch = Batch.create!(
        batch_id: SecureRandom.uuid,
        kind: "backfill",
        filters: query.to_h,
        snapshot_max_id: topics.maximum(:id) || 0,
        matched_count: topics.count,
      )
      Jobs.enqueue(Jobs::DiscourseIndexNow::GenerateBatch, batch_id: batch.batch_id)
      render json: { batch_id: batch.batch_id, status: batch.status }, status: :accepted
    end

    def retry_failed
      filter = LogFilter.new(params)
      ids = params[:log_ids]
      if params.key?(:log_ids)
        unless ids.is_a?(Array) && ids.present? && ids.size <= 10_000 && ids.all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }
          raise Discourse::InvalidParameters.new(:log_ids)
        end
        ids = ids.map(&:to_i).uniq
      end

      scope = filter.apply.where(status: :failed)
      scope = scope.where(id: ids) if ids.present?
      filters = filter.to_h
      filters["log_ids"] = ids if ids.present?
      batch = Batch.create!(
        batch_id: SecureRandom.uuid,
        kind: "retry",
        filters: filters,
        snapshot_max_id: scope.maximum(:id) || 0,
        matched_count: scope.count,
      )
      Jobs.enqueue(Jobs::DiscourseIndexNow::GenerateBatch, batch_id: batch.batch_id)
      render json: { batch_id: batch.batch_id, status: batch.status }, status: :accepted
    end

    def batch_status
      batch = Batch.find_by!(batch_id: params[:batch_id])
      render json: {
        batch_id: batch.batch_id,
        kind: batch.kind,
        status: batch.display_status,
        matched_count: batch.matched_count,
        processed_count: batch.processed_count,
        queued_count: batch.queued_count,
        skipped_count: batch.skipped_count,
        status_counts: SubmissionLog.where(batch_id: batch.batch_id).group(:status).count,
        retry_at: batch.retry_at,
        error_message: batch.error_message,
      }
    end

    def submit_urls
      lines = manual_url_lines(params[:urls])
      if lines.size > SubmissionService::BATCH_SIZE
        return render_manual_url_error
      end

      urls = valid_manual_urls(lines)
      return render_manual_url_error if urls.empty?

      entries = urls.map do |url|
        entry = { url: url, locale: nil }
        topic_id = Eligibility.topic_id_for_url(url)
        entry[:topic_id] = topic_id if topic_id.present?
        entry
      end
      result =
        SubmissionService.enqueue_batch(
          entries,
          source: "manual",
          trigger_reason: :manual,
        )

      render json: {
               submitted_urls: result[:submitted_count],
               batch_id: result[:batch_id],
             }
    end

    private

    def filtered_logs
      LogFilter.new(params).apply
    end

    def serialize_log(log)
      {
        id: log.id,
        url: log.url,
        batch_id: log.batch_id,
        batch_index: log.batch_index,
        locale: log.locale,
        status: log.status,
        trigger_reason: log.trigger_reason,
        response_code: log.response_code,
        error_message: log.error_message,
        created_at: log.created_at,
        updated_at: log.updated_at,
      }
    end

    def stats
      today = Time.zone.now.beginning_of_day
      failures = SubmissionLog.where(status: :failed).where("created_at >= ?", 7.days.ago)
      failure_breakdown = build_failure_breakdown(failures)
      key_accessible = KeyAccessibility.check(SiteSetting.indexnow_api_key)

      {
        enabled: SiteSetting.indexnow_enabled?,
        login_required: SiteSetting.login_required?,
         time_zone: Time.zone.name,
        api_key: SiteSetting.indexnow_api_key,
        key_accessible: key_accessible,
        key_accessibility_pending: key_accessible.nil?,
        key_accessibility_status: key_accessibility_status(key_accessible),
        today_success_count: SubmissionLog.where(status: :success).where("created_at >= ?", today).count,
        today_failed_count: SubmissionLog.where(status: :failed).where("created_at >= ?", today).count,
        trend_7d: trend_7d,
        failure_breakdown: failure_breakdown,
        usage: Throttle.usage,
        categories: Category.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
      }
    end

    def trend_7d
      6.downto(0).map do |days|
        day = Time.zone.now.to_date - days
        {
          date: day.to_s,
          success: SubmissionLog
            .where(status: :success)
            .where("created_at >= ? AND created_at < ?", day.beginning_of_day, day + 1.day)
            .count,
          failed: SubmissionLog
            .where(status: :failed)
            .where("created_at >= ? AND created_at < ?", day.beginning_of_day, day + 1.day)
            .count,
        }
      end
    end

    def key_accessibility_status(key_accessible)
      return "pending" if key_accessible.nil?

      key_accessible ? "accessible" : "unavailable"
    end

    def build_failure_breakdown(failures)
      messages = failures.pluck(:error_message, :response_code)
      total = messages.size

      counts = messages.each_with_object(Hash.new(0)) do |(message, response_code), result|
        result[classify_failure(message, response_code)] += 1
      end

      %i[rate_limit key_error domain_mismatch other].map do |category|
        count = counts[category]
        {
          category: category,
          count: count,
          percentage: total.zero? ? 0 : (count * 100.0 / total).round(1),
        }
      end
    end

    def classify_failure(message, response_code)
      text = "#{message} #{response_code}".downcase
      return :rate_limit if text.include?("429") || text.include?("rate_limit")
      return :key_error if text.include?("403") || text.include?("key")
      return :domain_mismatch if text.include?("422") || text.include?("domain")

      :other
    end

    def backfill_topics
      BackfillQuery.new(params).scope
    end

    def render_manual_url_error
      render(
        json: {
          errors: [I18n.t("js.discourse_index_now.admin.manual_no_valid")],
        },
        status: :unprocessable_entity,
      )
    end

    def manual_url_lines(raw)
      lines = Array(raw).join("\n").split(/[\r\n]+/).map(&:strip).reject(&:blank?)
      lines
    end

    def valid_manual_urls(lines)
      valid_urls = lines.filter_map do |line|
        begin
          uri = URI.parse(line)
        rescue URI::Error, ArgumentError
          next
        end

        next if %w[http https].exclude?(uri.scheme)
        next unless uri.host.to_s.downcase == Discourse.current_hostname.to_s.downcase
        next if manual_topic_ineligible?(uri)

        uri.to_s
      end

      valid_urls.uniq
    end

    def manual_topic_ineligible?(uri)
      uri.host = Discourse.current_hostname if uri.host.to_s.casecmp?(Discourse.current_hostname.to_s)
      route = Discourse.route_for(uri)
      if route.blank? || route[:topic_id].blank?
        return uri.path.to_s.start_with?("#{Discourse.base_path}/t/")
      end

      topic = Topic.find_by(id: route[:topic_id])
      topic.blank? || !Eligibility.eligible?(topic)
    end
  end
end
