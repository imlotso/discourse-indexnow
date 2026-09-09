# frozen_string_literal: true

require "securerandom"
require "uri"

module DiscourseIndexNow
  class AdminLogsController < ::Admin::AdminController
    requires_plugin DiscourseIndexNow::PLUGIN_NAME

    def index
      page = [params[:page].to_i, 1].max
      per_page = [[params[:per_page].to_i, 1].max, 50].min

      scope = SubmissionLog.order(created_at: :desc)
      scope = scope.where(status: status_value) unless status_value.nil?
      scope = scope.where("url ILIKE ?", "%#{url_filter}%") if url_filter.present?
      scope = scope.where(batch_id: batch_id_filter) if batch_id_filter.present?

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
      cancelled_count =
        filtered_logs.where(status: :pending).update_all(
          status: SubmissionLog.statuses[:cancelled],
          error_message: "cancelled_by_admin",
          updated_at: Time.zone.now,
        )

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
      entries = topics.flat_map { |topic| UrlBuilder.build_urls(topic) }

      render json: {
               matched_topics: topics.size,
               url_count: entries.size,
               urls: entries.first(100).map { |entry| entry[:url] },
             }
    end

    def backfill
      topics = backfill_topics
      entries = topics.flat_map { |topic| UrlBuilder.build_urls(topic) }
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

    def submit_urls
      lines = manual_url_lines(params[:urls])
      if lines.size > SubmissionService::BATCH_SIZE
        return render_manual_url_error
      end

      urls = valid_manual_urls(lines)
      return render_manual_url_error if urls.empty?

      entries = urls.map { |url| { url: url, locale: nil } }
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
      scope = SubmissionLog.all
      scope = scope.where(status: status_value) unless status_value.nil?
      scope = scope.where("url ILIKE ?", "%#{url_filter}%") if url_filter.present?
      scope = scope.where(batch_id: batch_id_filter) if batch_id_filter.present?
      scope
    end

    def status_value
      value = params[:status].presence
      return if value.blank?

      SubmissionLog.statuses[value]
    end

    def url_filter
      params[:url].to_s.strip
    end

    def batch_id_filter
      params[:batch_id].to_s.strip
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
      return Topic.none if SiteSetting.login_required?

      scope =
        Topic
          .joins(:category)
          .where(
            archetype: Archetype.default,
            deleted_at: nil,
            visible: true,
          )
          .where(categories: { read_restricted: false })
          .where.not(category_id: Eligibility.excluded_category_ids)

      excluded_tag_names = Eligibility.excluded_tag_names
      unless excluded_tag_names.empty?
        scope =
          scope.where.not(
            id: Topic.joins(:tags).where(tags: { name: excluded_tag_names }).select(:id),
          )
      end

      scope = scope.where(category_id: params[:category_id]) if params[:category_id].present?
      scope = scope.where("topics.created_at >= ?", parsed_date(:since)) if params[:since].present?
      scope = scope.where("topics.created_at <= ?", parsed_date(:until).end_of_day) if params[:until].present?
      scope.order(:id)
    end

    def parsed_date(name)
      Date.parse(params[name])
    rescue ArgumentError, TypeError
      raise Discourse::InvalidParameters.new(name)
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
      route = Discourse.route_for(uri)
      return false if route.blank? || route[:topic_id].blank?

      topic = Topic.find_by(id: route[:topic_id])
      topic.blank? || !Eligibility.eligible?(topic)
    end
  end
end
