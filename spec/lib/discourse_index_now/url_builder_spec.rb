# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::UrlBuilder do
  fab!(:topic)

  before do
    SiteSetting.set_locale_from_param = true
    SiteSetting.content_localization_enabled = true
    SiteSetting.content_localization_crawler_param = true
  end

  it "returns only the main URL when no localization exists" do
    expect(described_class.build_urls(topic)).to eq([{ url: topic.url, locale: nil }])
  end

  it "returns actual locale variants with the Discourse locale parameter" do
    Fabricate(:topic_localization, topic: topic, locale: "es")
    Fabricate(:topic_localization, topic: topic, locale: "zh_CN")

    urls = described_class.build_urls(topic)

    expect(urls.map { |entry| entry[:locale] }).to contain_exactly(nil, "es", "zh_CN")
    expect(urls.map { |entry| entry[:url] }).to contain_exactly(
      topic.url,
      "#{topic.url}?tl=es",
      "#{topic.url}?tl=zh_CN",
    )
  end

  it "does not build locale URLs when the crawler parameter is disabled" do
    Fabricate(:topic_localization, topic: topic, locale: "es")
    SiteSetting.content_localization_crawler_param = false

    expect(described_class.build_urls(topic)).to eq([{ url: topic.url, locale: nil }])
  end

  describe ".page_for" do
    it "maps post numbers onto crawler pages the way TopicView does" do
      size = TopicView.chunk_size

      expect(described_class.page_for(1)).to eq(1)
      expect(described_class.page_for(size)).to eq(1)
      expect(described_class.page_for(size + 1)).to eq(2)
      expect(described_class.page_for(size * 3)).to eq(3)
      expect(described_class.page_for(0)).to eq(1)
    end
  end

  describe "paged urls" do
    # Crawlers get the paginated view, and each page is its own canonical URL
    # (TopicView#current_page_path), so a reply late in a topic changes ?page=N.
    it "builds the page URL for pages past the first" do
      expect(described_class.page_url(topic, nil)).to eq(topic.url)
      expect(described_class.page_url(topic, 1)).to eq(topic.url)
      expect(described_class.page_url(topic, 4)).to eq("#{topic.url}?page=4")
    end

    it "keeps the locale param alongside the page param" do
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)
      Fabricate(:topic_localization, topic: topic, locale: "es")

      urls = described_class.build_urls(topic, page: 3).map { |entry| entry[:url] }

      expect(urls).to eq(["#{topic.url}?page=3", "#{topic.url}?page=3&tl=es"])
    end
  end
end
