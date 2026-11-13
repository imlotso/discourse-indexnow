# frozen_string_literal: true

module DiscourseIndexNow
  class SubmissionService
    # Fallback for the topic cooldown when the setting is absent, matching the
    # value this was hardcoded to before it became configurable.
    DEFAULT_COOLDOWN_MINUTES = 1
    CATEGORY_INELIGIBLE_REASON = "category_moved_ineligible"
    BATCH_SIZE = 10_000
    RESUBMIT_BATCH_SIZE = 1_000

    def self.handle_post_created(post)
      return unless SiteSetting.indexnow_enabled?

      # A reply changes the topic page as surely as an edit does, but it is much
      # higher volume, so it is opt-in and shares the per-topic cooldown.
      unless post.is_first_post?
        return unless SiteSetting.indexnow_submit_on_reply?
        return if post.deleted_at.present? || post.hidden
        return if Topic.visible_post_types.exclude?(post.post_type)
        page = crawler_page_for(post)
        return if page.nil?

        # Submit the crawler page the reply landed on, not the topic's base URL.
        # On a long topic those are different pages and only the former changed.
        return(
          enqueue_topic(
            post.topic,
            trigger_reason: :replied,
            page: page,
          )
        )
      end

      return unless SiteSetting.indexnow_submit_on_create?

      enqueue_topic(post.topic, trigger_reason: :created)
    end

    def self.handle_post_edited(post, topic_changed = false)
      return unless SiteSetting.indexnow_enabled?

      if SiteSetting.indexnow_submit_on_edit? && (post.is_first_post? || topic_changed)
        enqueue_topic(post.topic, trigger_reason: :edited)
      end

      return if post.is_first_post? || !SiteSetting.indexnow_submit_on_reply_edit?
      return if post.deleted_at.present? || post.hidden
      return if Topic.visible_post_types.exclude?(post.post_type)

      page = crawler_page_for(post)
      return if page.nil?
      return if topic_changed && SiteSetting.indexnow_submit_on_edit? && page <= 1

      enqueue_topic(post.topic, trigger_reason: :reply_edited, page: page)
    end

    def self.crawler_page_for(post)
      return unless Eligibility.eligible?(post.topic)

      UrlBuilder.page_for(post)
    rescue Discourse::InvalidAccess, Discourse::NotFound, Discourse::NotLoggedIn
      # Visibility can change between the eligibility check and TopicView.
      nil
    end

    def self.handle_topic_destroyed(topic)
      return unless SiteSetting.indexnow_enabled?
      return if topic.blank?
      return unless Eligibility.eligible_for_deletion?(topic)

      enqueue_deleted_topic(topic)
    end

    def self.handle_topic_localization_created(localization)
      return unless SiteSetting.indexnow_enabled?
      return unless SiteSetting.indexnow_submit_on_create?
      return if localization.blank?

      topic = localization.topic
      return if topic.blank?
      return if SiteSetting.indexnow_api_key.blank?
      return unless Eligibility.eligible?(topic)

      entry = UrlBuilder.build_locale_url(topic, localization.locale)
      enqueue_batch([entry].compact, topic_id: topic.id, trigger_reason: :created)
    end

    def self.handle_topic_changed(topic)
      return unless SiteSetting.indexnow_enabled?
      return if topic.blank?

      if Eligibility.eligible?(topic)
        enqueue_topic(topic, trigger_reason: :category_changed)
      else
        mark_topic_logs_failed(topic, CATEGORY_INELIGIBLE_REASON)
      end
    end

    def self.handle_category_updated(category)
      return unless SiteSetting.indexnow_enabled?
      return if category.blank?
      return unless category.saved_change_to_read_restricted?

      Jobs.enqueue(
        Jobs::DiscourseIndexNow::ResubmitTopics,
        category_id: category.id,
        mode: category.read_restricted? ? "revoke" : "submit",
        trigger_reason: "category_changed",
      )
    end

    def self.handle_tag_updated(tag)
      return unless SiteSetting.indexnow_enabled?
      return if tag.blank?

      Jobs.enqueue(
        Jobs::DiscourseIndexNow::ResubmitTopics,
        tag_id: tag.id,
        mode: "submit",
        trigger_reason: "edited",
      )
    end

    # Bulk counterpart to enqueue_topic, run from Jobs::DiscourseIndexNow::ResubmitTopics.
    #
    # Collects URLs in batches and hands each batch to enqueue_batch, which chunks at
    # the 10,000-URL protocol limit. One category or tag therefore costs a handful of
    # submission jobs rather than one per topic. enqueue_batch already skips URLs that
    # are still pending, so the per-topic redis debounce is not needed here.
    def self.resubmit_topics(
      category_id: nil,
      tag_id: nil,
      mode: "submit",
      trigger_reason: :category_changed
    )
      scope = resubmit_scope(category_id: category_id, tag_id: tag_id)
      return if scope.nil?

      if mode == "revoke"
        reason = category_id.present? ? "category_restricted" : "tag_ineligible"
        scope.find_each(batch_size: RESUBMIT_BATCH_SIZE) { |topic| mark_topic_logs_failed(topic, reason) }
        return
      end

      return if SiteSetting.indexnow_api_key.blank?

      scope.find_in_batches(batch_size: RESUBMIT_BATCH_SIZE) do |topics|
        entries =
          topics.flat_map do |topic|
            next [] unless Eligibility.eligible?(topic)

            UrlBuilder.build_urls(topic).map { |entry| entry.merge(topic_id: topic.id) }
          end
        next if entries.blank?

        enqueue_batch(entries, trigger_reason: trigger_reason)
      end
    end

    def self.resubmit_scope(category_id: nil, tag_id: nil)
      return Topic.where(category_id: category_id) if category_id.present?
      return Tag.find_by(id: tag_id)&.topics if tag_id.present?

      nil
    end

    def self.disable_if_login_required!
      SiteSetting.indexnow_enabled = false if SiteSetting.indexnow_enabled? &&
        SiteSetting.login_required?
    end

    def self.enqueue(topic)
      enqueue_topic(topic)
    end

    def self.enqueue_topic(topic, localized: true, trigger_reason: :created, page: nil)
      return if topic.blank?
      return if SiteSetting.indexnow_api_key.blank?
      return unless Eligibility.eligible?(topic)

      # The cooldown is claimed per URL rather than per topic, so a page that has
      # just started collecting replies is submitted straight away while the page
      # that filled up earlier stays capped. That keeps a busy topic to one
      # submission per page per window instead of one per reply.
      entries = build_url_entries(topic, localized: localized, page: page).select do |entry|
        if claim_cooldown(entry[:url])
          true
        else
          schedule_cooldown(topic.id, entry, trigger_reason)
          false
        end
      end
      return if entries.blank?

      result = enqueue_batch(entries, topic_id: topic.id, trigger_reason: trigger_reason)
      result[:skipped_entries].each { |entry| schedule_cooldown(topic.id, entry, trigger_reason) }
      result
    end

    def self.enqueue_batch(
      entries,
      topic_id: nil,
      source: nil,
      trigger_reason: :created,
      batch_id: SecureRandom.uuid,
      batch_index_start: 1,
      enqueue_jobs: true
    )
      entries =
        Array(entries)
          .filter_map do |entry|
            if entry.is_a?(String)
              { url: entry, locale: nil }
            elsif entry.respond_to?(:slice)
              normalized = entry.slice(:url, :locale, :topic_id, :retry_of_id, :trigger_reason)
              normalized if normalized[:url].present?
            end
          end
          .uniq { |entry| entry[:url] }
      return { batch_id: batch_id, submitted_count: 0, job_count: 0, skipped_entries: [] } if entries.blank?

      active = SubmissionLog.where(status: %i[pending processing retrying])
      # A deletion notice must survive an earlier in-flight create/edit job.
      active = active.where(trigger_reason: :deleted) if trigger_reason.to_s == "deleted"
      pending_urls = active.where(url: entries.map { |entry| entry[:url] }).pluck(:url).to_set
      skipped_entries = entries.select { |entry| pending_urls.include?(entry[:url]) }
      entries.reject! { |entry| pending_urls.include?(entry[:url]) }
      if entries.blank?
        return { batch_id: batch_id, submitted_count: 0, job_count: 0, skipped_entries: skipped_entries }
      end

      result = entries
        .each_slice(BATCH_SIZE)
        .with_index(batch_index_start)
        .map do |chunk, batch_index|
          logs =
            chunk.map do |entry|
              SubmissionLog.create!(
                url: entry[:url],
                locale: entry[:locale],
                topic_id: entry[:topic_id] || topic_id,
                retry_of_id: entry[:retry_of_id],
                batch_id: batch_id,
                batch_index: batch_index,
                status: :pending,
                trigger_reason: entry[:trigger_reason] || trigger_reason,
              )
            end

          if enqueue_jobs
            Jobs.enqueue(
              Jobs::DiscourseIndexNow::SubmitBatch,
              batch_id: batch_id,
              batch_index: batch_index,
              topic_id: topic_id,
            )
          end

          { batch_id: batch_id, submitted_count: logs.size, job_count: 1, source: source }
        end
        .reduce do |result, chunk_result|
          result[:submitted_count] += chunk_result[:submitted_count]
          result[:job_count] += chunk_result[:job_count]
          result
        end
      result[:skipped_entries] = skipped_entries
      result
    end

    def self.enqueue_deleted_topic(topic)
      return if SiteSetting.indexnow_api_key.blank?

      mark_topic_logs_failed(topic, "topic_destroyed")
      enqueue_batch(UrlBuilder.build_urls(topic), topic_id: topic.id, trigger_reason: :deleted)
    end

    # Keyed on the submitted URL, so each crawler page of a topic cools down
    # independently. Hashed because topic URLs are long and unbounded.
    def self.debounce_key(url)
      "indexnow:debounce:url:#{Digest::SHA256.hexdigest(url.to_s)}"
    end

    def self.deferred_key(url)
      "indexnow:deferred:url:#{Digest::SHA256.hexdigest(url.to_s)}"
    end

    def self.schedule_cooldown(topic_id, entry, trigger_reason)
      url = entry[:url]
      delay = [Discourse.redis.ttl(debounce_key(url)).to_i, 1].max
      return unless Discourse.redis.set(deferred_key(url), "1", nx: true, ex: delay + 1.hour.to_i)

      Jobs.enqueue_in(
        delay,
        Jobs::DiscourseIndexNow::FlushCooldown,
        topic_id: topic_id,
        url: url,
        locale: entry[:locale],
        trigger_reason: trigger_reason.to_s,
      )
    rescue StandardError
      Discourse.redis.del(deferred_key(url)) if url.present?
      raise
    end

    # Shortest gap between automatic submissions of the same URL. Every automatic
    # trigger -- created, edited, replied, category_changed -- shares the key for
    # a given URL, so a page costs one submission per window rather than one per
    # event, while a page that has not been submitted yet goes out immediately.
    #
    # Only automatic triggers go through here. Manual submissions and backfills
    # call enqueue_batch directly because an admin asked for those explicitly, and
    # deletion notices bypass it because they must always be delivered.
    def self.cooldown_seconds
      minutes = SiteSetting.indexnow_url_cooldown_minutes
      minutes = DEFAULT_COOLDOWN_MINUTES if minutes.nil?
      [minutes.to_i, 0].max * 60
    end

    # Returns true when this topic may be submitted now, taking the slot if so.
    # A cooldown of 0 disables the gate; enqueue_batch still drops URLs that are
    # already pending, so that does not mean duplicate rows.
    def self.claim_cooldown(url)
      seconds = cooldown_seconds
      return true if seconds.zero?

      Discourse.redis.set(debounce_key(url), "1", nx: true, ex: seconds).present?
    end

    def self.build_url_entries(topic, localized: true, page: nil)
      return [] if topic.blank?
      return [{ url: UrlBuilder.page_url(topic, page), locale: nil }] unless localized

      UrlBuilder
        .build_urls(topic, page: page)
        .select do |entry|
          entry[:locale].nil? || Eligibility.eligible_locales(topic, [entry[:locale]]).present?
        end
    end

    def self.mark_topic_logs_failed(topic, reason)
      mark_urls_failed(topic_urls(topic), reason)
    end

    def self.mark_urls_failed(urls, reason)
      urls = Array(urls).compact
      return if urls.blank?

      urls.each_slice(100) do |batch|
        conditions = batch.map { |_url| "(url = ? OR url LIKE ?)" }
        where_clause = conditions.join(" OR ")
        values = batch.flat_map { |url| [url, "#{url}?%"] }

        SubmissionLog
          .where(status: %i[pending retrying])
          .where(where_clause, *values)
          .update_all(
            status: SubmissionLog.statuses[:failed],
            error_message: reason,
            updated_at: Time.zone.now,
          )
      end
    end

    def self.topic_urls(topic)
      [topic.url] + UrlBuilder.build_urls(topic).map { |entry| entry[:url] }
    end
  end
end
