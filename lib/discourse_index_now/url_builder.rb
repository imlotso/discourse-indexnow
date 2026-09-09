# frozen_string_literal: true

module DiscourseIndexNow
  class UrlBuilder
    # Crawlers do not get the Ember app: Discourse serves them the paginated view
    # in app/views/topics/show.html.erb, chunked at TopicView::CHUNK_SIZE posts and
    # linked with rel="prev"/rel="next". Each of those pages is its own canonical
    # URL (TopicView#current_page_path), so a reply on a long topic changes
    # /t/slug/id?page=N, not /t/slug/id. Submitting the topic's base URL for a
    # reply would ask a search engine to re-fetch a page that did not change.
    def self.build_urls(topic, page: nil)
      return [] if topic.blank?

      base = page_url(topic, page)
      urls = [{ url: base, locale: nil }]
      return urls unless ::ContentLocalization.crawler_locale_param_enabled?

      locales = topic.localizations.order(:locale).pluck(:locale).uniq

      locales.each do |locale|
        urls << { url: locale_url(base, locale), locale: locale }
      end

      urls
    end

    def self.build_locale_url(topic, locale, page: nil)
      return if topic.blank? || locale.blank?
      return unless ::ContentLocalization.crawler_locale_param_enabled?

      { url: locale_url(page_url(topic, page), locale), locale: locale }
    end

    # Which crawler page a post number falls on. Mirrors TopicView#calculate_page
    # (((count - 1) / chunk_size) + 1); post_number stands in for the count, which
    # is what TopicView itself does on mega topics -- exactly the long threads
    # where this matters.
    def self.page_for(post_number)
      number = post_number.to_i
      return 1 if number < 1

      ((number - 1) / ::TopicView.chunk_size) + 1
    end

    def self.page_url(topic, page)
      return topic.url if page.nil? || page.to_i <= 1

      "#{topic.url}?page=#{page.to_i}"
    end

    def self.locale_url(url, locale)
      separator = url.include?("?") ? "&" : "?"
      "#{url}#{separator}#{::Discourse::LOCALE_PARAM}=#{ERB::Util.url_encode(locale)}"
    end
  end
end
