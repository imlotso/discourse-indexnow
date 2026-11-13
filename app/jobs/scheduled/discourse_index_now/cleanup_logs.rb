# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class CleanupLogs < ::Jobs::Scheduled
      every 1.day
      cluster_concurrency 1

      BATCH_SIZE = 1_000
      MAX_BATCHES = 100

      def execute(_args = nil)
        days = SiteSetting.indexnow_log_retention_days.to_i
        return if days <= 0

        scope = ::DiscourseIndexNow::SubmissionLog
          .where(status: %i[success failed cancelled])
          .where("updated_at < ?", days.days.ago)

        MAX_BATCHES.times do
          ids = scope.order(:id).limit(BATCH_SIZE).pluck(:id)
          break if ids.empty?

          scope.where(id: ids).delete_all
          break if ids.size < BATCH_SIZE
        end
      end
    end
  end
end
