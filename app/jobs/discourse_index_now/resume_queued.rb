# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class ResumeQueued < ::Jobs::Base
      def execute(_args)
        return unless SiteSetting.indexnow_enabled?
        return if SiteSetting.indexnow_hourly_limit.to_i <= 0 || SiteSetting.indexnow_daily_limit.to_i <= 0

        ::DiscourseIndexNow::SubmissionLog
          .where(status: %i[pending retrying], cancel_requested: false)
          .where("available_at IS NULL OR available_at <= ?", Time.zone.now)
          .where.not(batch_id: nil)
          .distinct
          .pluck(:batch_id, :batch_index)
          .each do |batch_id, batch_index|
            ::Jobs.enqueue(::Jobs::DiscourseIndexNow::SubmitBatch, batch_id: batch_id, batch_index: batch_index)
          end
      end
    end
  end
end
