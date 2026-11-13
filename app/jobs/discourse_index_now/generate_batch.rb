# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class GenerateBatch < ::Jobs::Base
      sidekiq_options retry: 5
      CHUNK_SIZE = 500
      MAX_RETRIES = 5
      RETRY_DELAYS = [60, 300, 900, 1800, 3600].freeze

      def execute(args)
        batch = ::DiscourseIndexNow::Batch.find_by(batch_id: args[:batch_id])
        return if batch.blank?
        return if batch.retry_at.present? && batch.retry_at > Time.zone.now

        resume_pending(batch) if batch.generation_attempt_count.positive?

        loop do
          indices = []
          finished = false
          batch.with_lock do
            if %w[cancelled failed generated].include?(batch.status)
              finished = true
              next
            end

            batch.update!(status: "running") if batch.status == "queued"
            records = source(batch)
              .where("#{source_table(batch)}.id > ? AND #{source_table(batch)}.id <= ?", batch.cursor, batch.snapshot_max_id.to_i)
              .reorder(:id)
              .limit(CHUNK_SIZE)
              .to_a
            if records.empty?
              missing = [batch.matched_count - batch.processed_count, 0].max
              batch.update!(
                status: "generated",
                skipped_count: batch.skipped_count + missing,
                generation_attempt_count: 0,
                retry_at: nil,
                error_message: nil,
              )
              finished = true
              next
            end

            entries, ineligible_count = batch.kind == "backfill" ? topic_entries(records) : retry_entries(records)
            first_index = batch.next_batch_index
            result = ::DiscourseIndexNow::SubmissionService.enqueue_batch(
              entries,
              batch_id: batch.batch_id,
              batch_index_start: first_index,
              enqueue_jobs: false,
              trigger_reason: batch.kind == "backfill" ? :backfill : :manual,
            )
            indices = (first_index...(first_index + result[:job_count])).to_a
            batch.update!(
              cursor: records.last.id,
              next_batch_index: first_index + result[:job_count],
              processed_count: batch.processed_count + records.size,
              queued_count: batch.queued_count + result[:submitted_count],
              skipped_count: batch.skipped_count + entries.size - result[:submitted_count] + ineligible_count,
              generation_attempt_count: 0,
              retry_at: nil,
              error_message: nil,
            )
          end

          indices.each do |index|
            ::Jobs.enqueue(::Jobs::DiscourseIndexNow::SubmitBatch, batch_id: batch.batch_id, batch_index: index)
          end
          break if finished
        end
      rescue StandardError => e
        raise if batch.blank?

        retry_generation(batch, e)
      end

      private

      def resume_pending(batch)
        ::DiscourseIndexNow::SubmissionLog
          .where(batch_id: batch.batch_id, status: %i[pending retrying], cancel_requested: false)
          .where("available_at IS NULL OR available_at <= ?", Time.zone.now)
          .distinct
          .pluck(:batch_index)
          .each do |index|
            ::Jobs.enqueue(::Jobs::DiscourseIndexNow::SubmitBatch, batch_id: batch.batch_id, batch_index: index)
          end
      end

      def retry_generation(batch, error)
        delay = nil
        batch.with_lock do
          return if batch.status == "cancelled"

          attempt = batch.generation_attempt_count + 1
          delay = RETRY_DELAYS.fetch(attempt - 1) if attempt <= MAX_RETRIES
          batch.update!(
            status: delay ? "running" : "failed",
            generation_attempt_count: attempt,
            retry_at: delay ? Time.zone.now + delay.seconds : nil,
            error_message: "#{error.class}: #{error.message}".truncate(1_000),
          )
        end
        ::Jobs.enqueue_in(delay, self.class, batch_id: batch.batch_id) if delay
      rescue StandardError
        # If the scheduler itself is unavailable, leave the checkpoint runnable
        # so Sidekiq's own retry or the stalled-batch recovery can pick it up.
        ::DiscourseIndexNow::Batch.where(id: batch.id).where.not(status: "cancelled").update_all(retry_at: nil)
        raise
      end

      def source(batch)
        if batch.kind == "backfill"
          ::DiscourseIndexNow::BackfillQuery.new(batch.filters).scope.includes(:category, :tags, :localizations)
        else
          filter = ::DiscourseIndexNow::LogFilter.new(batch.filters)
          logs = filter.apply.where(status: :failed)
          ids = batch.filters["log_ids"]
          ids.present? ? logs.where(id: ids) : logs
        end
      end

      def source_table(batch)
        batch.kind == "backfill" ? "topics" : "indexnow_submission_logs"
      end

      def topic_entries(topics)
        skipped = 0
        entries = topics.flat_map do |topic|
          unless ::DiscourseIndexNow::Eligibility.eligible?(topic)
            skipped += 1
            next []
          end

          ::DiscourseIndexNow::UrlBuilder.build_urls(topic).map { |entry| entry.merge(topic_id: topic.id) }
        end
        [entries, skipped]
      end

      def retry_entries(logs)
        entries = logs.filter_map do |log|
          next unless ::DiscourseIndexNow::Eligibility.eligible_log?(log)

          {
            url: log.url,
            locale: log.locale,
            topic_id: log.topic_id || ::DiscourseIndexNow::Eligibility.topic_id_for_url(log.url),
            retry_of_id: log.id,
            trigger_reason: log.trigger_reason,
          }
        end
        [entries, logs.size - entries.size]
      end
    end
  end
end
