# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class RecoverStalledLogs < ::Jobs::Scheduled
      every 5.minutes
      sidekiq_options retry: false
      cluster_concurrency 1

      STALLED_AFTER = 30.minutes
      CLAIM_TIMEOUT = 5.minutes
      STALLED_REASON = "stalled_no_active_job"
      BATCH_JOB_NAME = :"DiscourseIndexNow::SubmitBatch"
      BATCH_JOB_CLASS = "Jobs::DiscourseIndexNow::SubmitBatch"
      GENERATE_JOB_NAME = :"DiscourseIndexNow::GenerateBatch"
      GENERATE_JOB_CLASS = "Jobs::DiscourseIndexNow::GenerateBatch"

      def execute(_args = nil)
        return unless SiteSetting.indexnow_enabled?

        expired = ::DiscourseIndexNow::SubmissionLog
          .where(status: :processing)
          .where("claimed_at < ?", CLAIM_TIMEOUT.ago)
        recovered = []
        expired.distinct.pluck(:batch_id, :batch_index).each do |batch_id, batch_index|
          next if batch_id.present? && batch_job_active?(batch_id, batch_index)

          claims = expired.where(batch_id: batch_id, batch_index: batch_index)
          cancel_abandoned_claims(claims)
          changed = claims.where(cancel_requested: false).update_all(
            status: ::DiscourseIndexNow::SubmissionLog.statuses[:pending],
            claim_token: nil,
            claimed_at: nil,
            updated_at: Time.zone.now,
          )
          cancel_abandoned_claims(claims)
          recovered << [batch_id, batch_index] if changed.positive? && batch_id.present?
        end

        ::DiscourseIndexNow::Batch
          .where(status: %w[queued running])
          .where("retry_at IS NULL OR retry_at <= ?", Time.zone.now)
          .where("updated_at < ?", STALLED_AFTER.ago)
          .pluck(:batch_id)
          .each do |batch_id|
            next if generation_job_active?(batch_id)

            ::Jobs.enqueue(::Jobs::DiscourseIndexNow::GenerateBatch, batch_id: batch_id)
          end

        return if SiteSetting.indexnow_hourly_limit.to_i <= 0 || SiteSetting.indexnow_daily_limit.to_i <= 0

        recovered.each do |batch_id, batch_index|
          ::Jobs.enqueue(::Jobs::DiscourseIndexNow::SubmitBatch, batch_id: batch_id, batch_index: batch_index)
        end

        cutoff = STALLED_AFTER.ago

        ::DiscourseIndexNow::SubmissionLog
          .where(status: %i[pending retrying], cancel_requested: false)
          .where("available_at IS NULL OR available_at <= ?", Time.zone.now)
          .where("created_at < ?", cutoff)
          .group(:batch_id, :batch_index)
          .pluck(:batch_id, :batch_index)
          .each do |batch_id, batch_index|
            next if recovered.include?([batch_id, batch_index])
            next if batch_job_active?(batch_id, batch_index)

            ::Jobs.enqueue(
              ::Jobs::DiscourseIndexNow::SubmitBatch,
              batch_id: batch_id,
              batch_index: batch_index,
            )
          end

        mark_orphaned_logs_failed(cutoff)
      end

      private

      def cancel_abandoned_claims(scope)
        scope.where(cancel_requested: true).update_all(
          status: ::DiscourseIndexNow::SubmissionLog.statuses[:cancelled],
          error_message: "cancelled_by_admin",
          claim_token: nil,
          claimed_at: nil,
          available_at: nil,
          updated_at: Time.zone.now,
        )
      end

      def batch_job_active?(batch_id, batch_index)
        return true if ::Jobs.scheduled_for(
          BATCH_JOB_NAME,
          batch_id: batch_id,
          batch_index: batch_index,
        ).present?

        queued = [Sidekiq::RetrySet.new, Sidekiq::Queue.new].any? do |job_set|
          job_set.any? { |job| matches_batch_job?(job, batch_id, batch_index) }
        end
        return true if queued

        Sidekiq::Workers.new.any? do |_process, _thread, work|
          payload = work["payload"] || work[:payload]
          payload = JSON.parse(payload) if payload.is_a?(String)
          payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)
          payload.present? && matches_batch_payload?(payload[:class], payload[:args], batch_id, batch_index)
        end
      end

      def matches_batch_job?(job, batch_id, batch_index)
        matches_batch_payload?(job.klass, job.args, batch_id, batch_index)
      end

      def generation_job_active?(batch_id)
        return true if ::Jobs.scheduled_for(GENERATE_JOB_NAME, batch_id: batch_id).present?

        queued = [Sidekiq::RetrySet.new, Sidekiq::Queue.new].any? do |jobs|
          jobs.any? { |job| matches_generation_payload?(job.klass, job.args, batch_id) }
        end
        return true if queued

        Sidekiq::Workers.new.any? do |_process, _thread, work|
          payload = work["payload"] || work[:payload]
          payload = JSON.parse(payload) if payload.is_a?(String)
          payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)
          payload.present? && matches_generation_payload?(payload[:class], payload[:args], batch_id)
        end
      rescue JSON::ParserError, TypeError
        false
      end

      def matches_generation_payload?(job_class, args, batch_id)
        return false if job_class.to_s != GENERATE_JOB_CLASS

        raw = Array(args).first
        raw = JSON.parse(raw) if raw.is_a?(String)
        raw.is_a?(Hash) && raw.with_indifferent_access[:batch_id] == batch_id
      rescue JSON::ParserError, TypeError
        false
      end

      def matches_batch_payload?(job_class, args, batch_id, batch_index)
        return false if job_class.to_s != BATCH_JOB_CLASS

        raw_params = Array(args).first
        params = JSON.parse(raw_params) if raw_params.is_a?(String)
        params = raw_params if raw_params.is_a?(Hash)
        params ||= {}
        params = params.with_indifferent_access
        params[:batch_id] == batch_id && params[:batch_index] == batch_index
      rescue JSON::ParserError, TypeError
        false
      end

      def mark_orphaned_logs_failed(cutoff)
        ::DiscourseIndexNow::SubmissionLog
          .where(status: %i[pending retrying])
          .where("created_at < ?", cutoff)
          .where(batch_id: nil)
          .update_all(
            status: ::DiscourseIndexNow::SubmissionLog.statuses[:failed],
            error_message: STALLED_REASON,
            updated_at: Time.zone.now,
          )
      end
    end
  end
end
