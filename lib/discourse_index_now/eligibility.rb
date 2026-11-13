# frozen_string_literal: true

require "uri"

module DiscourseIndexNow
  class Eligibility
    def self.eligible?(topic)
      return false if topic.blank?
      return false if topic.deleted_at.present?

      base_eligible?(topic)
    end

    def self.eligible_for_deletion?(topic)
      return false if topic.blank?

      base_eligible?(topic)
    end

    # Older queued batches did not persist topic IDs. Recover them through the
    # same route recognition used for manually submitted URLs; never assume an
    # unrecognised topic URL is public.
    def self.topic_id_for_url(url)
      uri = URI.parse(url.to_s)
      return unless same_site_uri?(uri)

      uri.host = Discourse.current_hostname
      route = Discourse.route_for(uri)
      route && route[:topic_id].presence&.to_i
    rescue URI::Error, ArgumentError
      nil
    end

    def self.eligible_log?(log, legacy_topic_id: nil, topics: nil)
      return false if SiteSetting.login_required?

      uri = URI.parse(log.url.to_s)
      return false unless same_site_uri?(uri)

      route_topic_id = topic_id_for_url(log.url)
      recorded_topic_id = log.topic_id.presence || legacy_topic_id.presence
      return false if recorded_topic_id && route_topic_id != recorded_topic_id.to_i

      topic_id = recorded_topic_id || route_topic_id
      if topic_id.present?
        topic = topics ? topics[topic_id.to_i] : Topic.with_deleted.find_by(id: topic_id)
        return log.trigger_reason == "deleted" ? eligible_for_deletion?(topic) : eligible?(topic)
      end

      # The manual interface also supports public non-topic pages such as
      # /categories. Unknown topic-looking URLs fail closed.
      topic_path = "#{Discourse.base_path}/t/"
      log.trigger_reason == "manual" && !uri.path.to_s.start_with?(topic_path)
    rescue URI::Error, ArgumentError
      false
    end

    def self.same_site_uri?(uri)
      %w[http https].include?(uri.scheme) &&
        uri.host.to_s.casecmp?(Discourse.current_hostname.to_s)
    end

    # Locale variants share the topic and category visibility rules. Keeping
    # this method separate leaves room for locale-specific exclusions later.
    def self.eligible_locales(topic, locales)
      return [] unless eligible?(topic)

      locales.to_a.compact.uniq
    end

    def self.excluded_category_ids
      SiteSetting
        .indexnow_excluded_category_ids
        .to_s
        .split("|")
        .map(&:to_i)
        .reject(&:zero?)
    end

    def self.excluded_tag?(topic)
      excluded = excluded_tag_names
      return false if excluded.empty?

      names = topic.association(:tags).loaded? ? topic.tags.map(&:name) : topic.tags.pluck(:name)
      (names & excluded).any?
    end

    def self.excluded_tag_names
      SiteSetting
        .indexnow_excluded_tag_names
        .to_s
        .split("|")
        .map(&:strip)
        .reject(&:blank?)
        .uniq
    end

    def self.base_eligible?(topic)
      return false if SiteSetting.login_required?
      return false if topic.archetype == Archetype.private_message
      return false if topic.category&.read_restricted
      return false unless topic.visible
      return false if excluded_category_ids.include?(topic.category_id)
      return false if excluded_tag?(topic)

      true
    end
end
end
