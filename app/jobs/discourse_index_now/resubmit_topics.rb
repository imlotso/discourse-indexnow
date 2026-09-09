# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    # Re-submits (or revokes) every topic in a category or carrying a tag.
    #
    # This runs off the web request on purpose. The :category_updated and
    # :tag_updated events fire inside the save that triggered them, so doing the
    # fan-out inline meant a single category visibility toggle or tag rename walked
    # every topic and created one log row plus one Sidekiq job per topic while an
    # admin's request was still open. On a large forum that is tens of thousands of
    # jobs enqueued synchronously.
    class ResubmitTopics < ::Jobs::Base
      def execute(args)
        ::DiscourseIndexNow::SubmissionService.resubmit_topics(
          category_id: args[:category_id],
          tag_id: args[:tag_id],
          mode: args[:mode].presence || "submit",
          trigger_reason: (args[:trigger_reason].presence || "category_changed").to_sym,
        )
      end
    end
  end
end
