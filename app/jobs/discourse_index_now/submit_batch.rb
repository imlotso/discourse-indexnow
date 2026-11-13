# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class SubmitBatch < ::Jobs::Base
      sidekiq_options retry: 5

      MAX_RETRIES = 5
      RETRY_DELAYS = [60, 300, 900, 1800, 3600].freeze
      CLAIM_LIMIT = 500

      def execute(args)
        batch_id = args[:batch_id]
        batch_index = args.fetch(:batch_index, 0)
        scope = ::DiscourseIndexNow::SubmissionLog.where(batch_id: batch_id, batch_index: batch_index)
        ready = scope.where(status: %i[pending retrying], cancel_requested: false).where(
          "available_at IS NULL OR available_at <= ?",
          Time.zone.now,
        )
        return if ready.empty?

        unless SiteSetting.indexnow_enabled? && SiteSetting.indexnow_api_key.present?
          finish(ready, :failed, nil, "plugin_disabled")
          return
        end

        # A zero cap is a paused queue. The recovery job wakes it after the
        # setting changes; it must not create a new job every minute.
        return if limits_paused?

        capacity_hint = ::DiscourseIndexNow::Throttle.available_capacity
        if capacity_hint <= 0
          schedule_remaining(args)
          return
        end

        token = SecureRandom.uuid
        claimed_ids = claim(ready, token, [capacity_hint, CLAIM_LIMIT].min)
        return if claimed_ids.empty?

        claimed = scope.where(id: claimed_ids, status: :processing, claim_token: token).order(:id)
        ineligible = ineligible_ids(claimed, args[:topic_id])
        finish(claimed.where(id: ineligible), :failed, nil, "ineligible_at_execution") if ineligible.present?

        eligible = claimed.where.not(id: ineligible)
        eligible_ids = eligible.pluck(:id)
        if eligible_ids.empty?
          schedule_remaining(args) if ready.exists?
          return
        end

        reserved = ::DiscourseIndexNow::Throttle.reserve!(eligible_ids.size)
        sending_ids = eligible_ids.first(reserved)
        remaining_ids = eligible_ids.drop(reserved)
        release(eligible.where(id: remaining_ids)) if remaining_ids.present?
        schedule_remaining(args) if ready.exists?
        return if sending_ids.empty?

        sending = claimed.where(id: sending_ids)
        # Eligibility may have changed while another part of this batch was
        # waiting for quota. Check again immediately before the HTTP request.
        stale = ineligible_ids(sending, args[:topic_id])
        finish(sending.where(id: stale), :failed, nil, "ineligible_at_execution") if stale.present?
        sending = sending.where.not(id: stale)
        finish(sending.where(cancel_requested: true), :cancelled, nil, "cancelled_by_admin")
        selected = sending.where(cancel_requested: false).pluck(:id, :url)
        return if selected.empty?

        sending = sending.where(id: selected.map(&:first))
        urls = selected.map(&:last)

        result = ::DiscourseIndexNow::Client.submit_batch(urls)
        if result[:success]
          finish(sending, :success, result[:status], nil)
        elsif retryable?(result)
          schedule_retry(sending, result, args)
        else
          finish(sending, :failed, result[:status], result[:error])
        end
      end

      private

      def ineligible_ids(scope, legacy_topic_id)
        logs = scope.to_a
        ids = logs.filter_map do |log|
          log.topic_id.presence || legacy_topic_id.presence || ::DiscourseIndexNow::Eligibility.topic_id_for_url(log.url)
        end.uniq
        topics = Topic.with_deleted.where(id: ids).includes(:category, :tags).index_by(&:id)
        logs.filter_map do |log|
          unless ::DiscourseIndexNow::Eligibility.eligible_log?(log, legacy_topic_id: legacy_topic_id, topics: topics)
            log.id
          end
        end
      end

      def claim(scope, token, limit)
        ids = []
        ::DiscourseIndexNow::SubmissionLog.transaction do
          ids = scope.order(:id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
          scope.where(id: ids).update_all(
            status: ::DiscourseIndexNow::SubmissionLog.statuses[:processing],
            claim_token: token,
            claimed_at: Time.zone.now,
            updated_at: Time.zone.now,
          )
        end
        ids
      end

      def limits_paused?
        SiteSetting.indexnow_hourly_limit.to_i <= 0 || SiteSetting.indexnow_daily_limit.to_i <= 0
      end

      def release(scope)
        finish(scope.where(cancel_requested: true), :cancelled, nil, "cancelled_by_admin")
        scope.where(cancel_requested: false).update_all(
          status: ::DiscourseIndexNow::SubmissionLog.statuses[:pending],
          claim_token: nil,
          claimed_at: nil,
          available_at: nil,
          updated_at: Time.zone.now,
        )
        finish(scope.where(cancel_requested: true), :cancelled, nil, "cancelled_by_admin")
      end

      def schedule_remaining(args)
        return if limits_paused?

        delay = if ::DiscourseIndexNow::Throttle.available_capacity.positive?
          1
        else
          [::DiscourseIndexNow::Throttle.next_window_delay.to_i, 1].max
        end
        ::Jobs.enqueue_in(delay, ::Jobs::DiscourseIndexNow::SubmitBatch, args)
      end

      def retryable?(result)
        status = result[:status].to_i
        status.zero? || status == 408 || status == 429 || status >= 500
      end

      def schedule_retry(scope, result, args)
        if result[:status] == 429
          delay = result[:retry_after].to_i.positive? ? result[:retry_after].to_i : RETRY_DELAYS.first
          ::DiscourseIndexNow::Throttle.throttle_until!(Time.zone.now + delay.seconds)
        end

        finish(scope.where(cancel_requested: true), :cancelled, result[:status], "cancelled_by_admin")
        active = scope.where(cancel_requested: false)
        active.to_a.group_by { |log| log.attempt_count.to_i + 1 }.each do |attempt, logs|
          ids = logs.map(&:id)
          selected = active.where(id: ids)
          if attempt > MAX_RETRIES
            selected.update_all(attempt_count: attempt)
            finish(selected, :failed, result[:status], result[:error])
            next
          end

          delay = result[:retry_after].to_i
          delay = RETRY_DELAYS.fetch(attempt - 1) unless delay.positive?
          updated = selected.update_all(
            status: ::DiscourseIndexNow::SubmissionLog.statuses[:retrying],
            attempt_count: attempt,
            response_code: result[:status],
            error_message: result[:error],
            available_at: Time.zone.now + delay.seconds,
            claim_token: nil,
            claimed_at: nil,
            updated_at: Time.zone.now,
          )
          ::Jobs.enqueue_in(delay, ::Jobs::DiscourseIndexNow::SubmitBatch, args) if updated.positive?
        end
        finish(scope.where(cancel_requested: true), :cancelled, result[:status], "cancelled_by_admin")
      end

      def finish(scope, status, response_code, error_message)
        scope.update_all(
          status: ::DiscourseIndexNow::SubmissionLog.statuses[status],
          response_code: response_code,
          error_message: error_message,
          available_at: nil,
          claim_token: nil,
          claimed_at: nil,
          updated_at: Time.zone.now,
        )
      end
    end
  end
end
