# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class FlushCooldown < ::Jobs::Base
      sidekiq_options retry: 5

      def execute(args)
        service = ::DiscourseIndexNow::SubmissionService
        url = args[:url].to_s
        return if url.blank?

        rescheduled = false
        topic = Topic.find_by(id: args[:topic_id])
        return unless SiteSetting.indexnow_enabled? && SiteSetting.indexnow_api_key.present?
        return unless ::DiscourseIndexNow::Eligibility.eligible?(topic)

        active = ::DiscourseIndexNow::SubmissionLog.where(url: url, status: %i[pending retrying processing])
        return if active.where(status: %i[pending retrying]).exists?

        if active.where(status: :processing).exists? || !service.claim_cooldown(url)
          delay = [Discourse.redis.ttl(service.debounce_key(url)).to_i, 10].max
          ::Jobs.enqueue_in(delay, self.class, args)
          rescheduled = true
          return
        end

        service.enqueue_batch(
          [{ url: url, locale: args[:locale] }],
          topic_id: topic.id,
          trigger_reason: args[:trigger_reason].presence&.to_sym || :edited,
        )
      ensure
        Discourse.redis.del(service.deferred_key(url)) if service && url.present? && !rescheduled
      end
    end
  end
end
