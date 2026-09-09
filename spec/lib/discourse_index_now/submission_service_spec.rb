# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::SubmissionService do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    SiteSetting.indexnow_submit_on_create = true
    SiteSetting.indexnow_submit_on_edit = true
    SiteSetting.login_required = false
    SiteSetting.indexnow_excluded_tag_names = ""
    Discourse.redis.del(described_class.debounce_key(topic.url))
    allow(Jobs).to receive(:enqueue)
  end

  after { Discourse.redis.del(described_class.debounce_key(topic.url)) }

  describe "#handle_post_created" do
    it "creates one log per URL in a localized batch" do
      SiteSetting.indexnow_enabled = false
      Fabricate(:topic_localization, topic: topic, locale: "es")
      Fabricate(:topic_localization, topic: topic, locale: "zh_CN")
      SiteSetting.indexnow_enabled = true
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)

      described_class.handle_post_created(post)

      logs = DiscourseIndexNow::SubmissionLog.order(:id).all
      expect(logs.map(&:url)).to eq([topic.url, "#{topic.url}?tl=es", "#{topic.url}?tl=zh_CN"])
      expect(logs.map(&:locale)).to eq([nil, "es", "zh_CN"])
      expect(logs.map(&:batch_id).uniq).to contain_exactly(logs.first.batch_id)
      expect(logs.map(&:batch_index).uniq).to eq([1])
      expect(logs.map(&:trigger_reason).uniq).to eq(%w[created])
      expect(Jobs).to have_received(:enqueue).with(
        Jobs::DiscourseIndexNow::SubmitBatch,
        batch_id: logs.first.batch_id,
        batch_index: 1,
        topic_id: topic.id,
      )
    end

    it "submits only the main URL when crawler locale URLs are disabled" do
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(false)
      Fabricate(:topic_localization, topic: topic, locale: "es")

      described_class.handle_post_created(post)

      expect(DiscourseIndexNow::SubmissionLog.pluck(:url, :locale)).to eq([[topic.url, nil]])
    end

    it "submits a locale URL when its translation is created after the initial submission" do
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)

      described_class.handle_post_created(post)
      SiteSetting.indexnow_enabled = false
      localization = Fabricate(:topic_localization, topic: topic, locale: "es")
      SiteSetting.indexnow_enabled = true
      described_class.handle_topic_localization_created(localization)

      logs = DiscourseIndexNow::SubmissionLog.order(:id).all
      expect(logs.map(&:url)).to eq([topic.url, "#{topic.url}?tl=es"])
      expect(logs.map(&:locale)).to eq([nil, "es"])
      expect(logs.map(&:trigger_reason)).to eq(%w[created created])
      expect(Jobs).to have_received(:enqueue).twice
    end

    it "does not duplicate locale URLs when translation is already available" do
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)

      SiteSetting.indexnow_enabled = false
      Fabricate(:topic_localization, topic: topic, locale: "es")
      SiteSetting.indexnow_enabled = true

      described_class.handle_post_created(post)

      expect(DiscourseIndexNow::SubmissionLog.order(:id).pluck(:url)).to eq(
        [topic.url, "#{topic.url}?tl=es"],
      )
    end

    it "does not submit a late translation when create submissions are disabled" do
      SiteSetting.indexnow_submit_on_create = false
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)

      Fabricate(:topic_localization, topic: topic, locale: "es")

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(0)
    end
  end

  describe "replies" do
    fab!(:reply) { Fabricate(:post, topic: topic, post_number: 2) }

    it "ignores replies by default" do
      expect { described_class.handle_post_created(reply) }.not_to change(
        DiscourseIndexNow::SubmissionLog,
        :count,
      )
    end

    it "submits the topic for a reply once enabled" do
      SiteSetting.indexnow_submit_on_reply = true

      described_class.handle_post_created(reply)

      expect(DiscourseIndexNow::SubmissionLog.pluck(:url)).to contain_exactly(topic.url)
      expect(DiscourseIndexNow::SubmissionLog.first.trigger_reason).to eq("replied")
    end

    it "still submits the first post as created, not replied" do
      SiteSetting.indexnow_submit_on_reply = true

      described_class.handle_post_created(post)

      expect(DiscourseIndexNow::SubmissionLog.first.trigger_reason).to eq("created")
    end
  end

  describe "url cooldown" do
    fab!(:reply) { Fabricate(:post, topic: topic, post_number: 2) }

    before { SiteSetting.indexnow_submit_on_reply = true }

    # Replies to the same crawler page collapse into one submission per window.
    it "collapses repeated activity on one page into a single submission" do
      SiteSetting.indexnow_url_cooldown_minutes = 1440

      3.times { described_class.handle_post_created(reply) }
      described_class.handle_post_edited(post, false)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(1)
    end

    # ...but a reply that rolls the topic onto a new crawler page is a new URL,
    # so it goes out immediately rather than waiting behind the previous page.
    it "submits a new page straight away while the previous page is cooling down" do
      SiteSetting.indexnow_url_cooldown_minutes = 1440
      described_class.handle_post_created(reply)

      later = Fabricate(:post, topic: topic, post_number: TopicView.chunk_size + 5)
      described_class.handle_post_created(later)

      expect(DiscourseIndexNow::SubmissionLog.order(:id).pluck(:url)).to eq(
        [topic.url, "#{topic.url}?page=2"],
      )
    end

    it "sets the cooldown to the configured length" do
      SiteSetting.indexnow_url_cooldown_minutes = 1440

      described_class.handle_post_created(reply)

      expect(Discourse.redis.ttl(described_class.debounce_key(topic.url))).to be > 86_000
    end

    it "does not gate submissions when the cooldown is zero" do
      SiteSetting.indexnow_url_cooldown_minutes = 0
      described_class.handle_post_created(reply)
      # Settle the first log so the pending-URL guard is not what is being measured.
      DiscourseIndexNow::SubmissionLog.update_all(
        status: DiscourseIndexNow::SubmissionLog.statuses[:success],
      )

      described_class.handle_post_created(reply)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(2)
    end

    it "lets a deletion through even while the topic is cooling down" do
      SiteSetting.indexnow_url_cooldown_minutes = 1440
      described_class.handle_post_created(reply)

      described_class.enqueue_deleted_topic(topic)

      expect(DiscourseIndexNow::SubmissionLog.where(trigger_reason: :deleted)).to be_present
    end
  end

  describe "#handle_post_edited" do
    it "does not submit ordinary non-first-post edits" do
      reply = Fabricate(:post, topic: topic, post_number: 2)

      described_class.handle_post_edited(reply, false)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(0)
    end

    it "submits when the topic itself changed during an edit" do
      reply = Fabricate(:post, topic: topic, post_number: 2)

      described_class.handle_post_edited(reply, true)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(1)
      expect(DiscourseIndexNow::SubmissionLog.first.trigger_reason).to eq("edited")
    end
  end

  describe "#enqueue_topic" do
    it "debounces on the topic id" do
      described_class.enqueue(topic)
      described_class.enqueue(topic)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(1)
      expect(Discourse.redis.get(described_class.debounce_key(topic.url))).to eq("1")
    end

    it "skips a topic in a read-restricted category" do
      category.update!(read_restricted: true)

      expect { described_class.enqueue(topic) }.not_to change(
        DiscourseIndexNow::SubmissionLog,
        :count,
      )
    end

    it "does nothing when the plugin is disabled" do
      SiteSetting.indexnow_enabled = false

      expect { described_class.handle_post_created(post) }.not_to change(
        DiscourseIndexNow::SubmissionLog,
        :count,
      )
    end
  end

  describe "#enqueue_batch" do
    it "accepts plain URLs and splits logical batches into chunks" do
      urls = []
      result = nil
      stub_const(described_class, :BATCH_SIZE, 2) do
        urls = %w[
          https://forum.example.com/t/one/1
          https://forum.example.com/t/two/2
          https://forum.example.com/t/three/3
        ]

        result = described_class.enqueue_batch(urls, source: "backfill", trigger_reason: :backfill)
      end

      logs = DiscourseIndexNow::SubmissionLog.order(:id).all
      expect(result[:submitted_count]).to eq(3)
      expect(result[:job_count]).to eq(2)
      expect(result[:source]).to eq("backfill")
      expect(logs.map(&:trigger_reason).uniq).to eq(%w[backfill])
      expect(logs.map(&:batch_id).uniq).to contain_exactly(result[:batch_id])
      expect(logs.map(&:batch_index)).to eq([1, 1, 2])
      expect(Jobs).to have_received(:enqueue).twice
    end
  end

  describe "#handle_topic_destroyed" do
    it "marks stale pending URLs failed and submits all topic URLs for deletion" do
      allow(ContentLocalization).to receive(:crawler_locale_param_enabled?).and_return(true)
      Fabricate(:topic_localization, topic: topic, locale: "es")
      Fabricate(:topic_localization, topic: topic, locale: "zh_CN")
      described_class.enqueue(topic)
      topic.update!(deleted_at: Time.zone.now)
      described_class.handle_topic_destroyed(topic)

      stale_logs = DiscourseIndexNow::SubmissionLog.where(trigger_reason: :created)
      deletion_logs = DiscourseIndexNow::SubmissionLog.where(trigger_reason: :deleted)
      expect(stale_logs).to all(be_failed)
      expect(stale_logs.map(&:error_message).uniq).to eq(["topic_destroyed"])
      expect(deletion_logs.map(&:url)).to eq(
        [topic.url, "#{topic.url}?tl=es", "#{topic.url}?tl=zh_CN"],
      )
      expect(deletion_logs.map(&:locale)).to eq([nil, "es", "zh_CN"])
      expect(deletion_logs).to all(be_pending)
      expect(Jobs).to have_received(:enqueue).with(
        Jobs::DiscourseIndexNow::SubmitBatch,
        { batch_id: deletion_logs.first.batch_id, batch_index: 1, topic_id: nil },
      )
    end

    it "does not submit a deleted topic from a restricted category" do
      topic.update!(
        deleted_at: Time.zone.now,
        category: Fabricate(:category, read_restricted: true),
      )

      expect { described_class.handle_topic_destroyed(topic) }.not_to change(
        DiscourseIndexNow::SubmissionLog,
        :count,
      )
    end

    it "submits when the author deletes their own first post without trashing the topic" do
      SiteSetting.delete_removed_posts_after = 72

      PostDestroyer.new(post.user, post).destroy

      expect(topic.reload.deleted_at).to be_blank
      expect(topic.reload.closed).to eq(true)
      expect(DiscourseIndexNow::SubmissionLog.where(trigger_reason: :deleted).count).to eq(1)
    end

    it "submits a soft-deleted topic through the real destruction event" do
      PostDestroyer.new(Discourse.system_user, post, context: "spec_topic_deletion").destroy

      expect(topic.reload.deleted_at).to be_present
      logs = DiscourseIndexNow::SubmissionLog.where(trigger_reason: :deleted)
      expect(logs.map(&:url)).to eq([topic.url])
    end
  end

  describe "#handle_topic_changed" do
    it "resubmits an eligible topic after it moves category" do
      described_class.handle_topic_changed(topic)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(1)
      expect(DiscourseIndexNow::SubmissionLog.first.trigger_reason).to eq("category_changed")
    end

    it "marks pending logs failed when the new category is excluded" do
      described_class.enqueue(topic)
      SiteSetting.indexnow_excluded_category_ids = category.id.to_s
      described_class.handle_topic_changed(topic)

      expect(DiscourseIndexNow::SubmissionLog.where(url: topic.url)).to all(be_failed)
    end
  end

  describe "#handle_category_updated" do
    # The fan-out itself is deferred: walking every topic in a category inline would
    # run inside the admin's own request. The handler's job is only to enqueue.
    it "defers the fan-out to a background job when a category becomes restricted" do
      category.update!(read_restricted: true)

      expect(Jobs).to have_received(:enqueue).with(
        Jobs::DiscourseIndexNow::ResubmitTopics,
        category_id: category.id,
        mode: "revoke",
        trigger_reason: "category_changed",
      )
    end

    it "defers the fan-out to a background job when a category becomes public" do
      restricted = Fabricate(:category, read_restricted: true)
      restricted.update!(read_restricted: false)

      expect(Jobs).to have_received(:enqueue).with(
        Jobs::DiscourseIndexNow::ResubmitTopics,
        category_id: restricted.id,
        mode: "submit",
        trigger_reason: "category_changed",
      )
    end

    it "does not enqueue anything when read_restricted did not change" do
      category.update!(name: "a different name")

      expect(Jobs).not_to have_received(:enqueue).with(
        Jobs::DiscourseIndexNow::ResubmitTopics,
        any_args,
      )
    end
  end

  describe "#handle_tag_updated" do
    it "defers the fan-out to a background job" do
      tag = Fabricate(:tag)
      tag.update!(name: "renamed-tag")

      expect(Jobs).to have_received(:enqueue).with(
        Jobs::DiscourseIndexNow::ResubmitTopics,
        tag_id: tag.id,
        mode: "submit",
        trigger_reason: "edited",
      )
    end
  end

  describe "#resubmit_topics" do
    it "fails pending logs for a category that became restricted" do
      described_class.enqueue(topic)

      described_class.resubmit_topics(category_id: category.id, mode: "revoke")

      expect(DiscourseIndexNow::SubmissionLog.where(url: topic.url)).to all(be_failed)
    end

    it "submits every eligible topic in a category" do
      described_class.resubmit_topics(category_id: category.id, trigger_reason: :category_changed)

      expect(DiscourseIndexNow::SubmissionLog.pluck(:url)).to contain_exactly(topic.url)
      expect(DiscourseIndexNow::SubmissionLog.first.trigger_reason).to eq("category_changed")
    end

    it "submits every topic carrying a tag" do
      tag = Fabricate(:tag)
      topic.tags << tag

      described_class.resubmit_topics(tag_id: tag.id, trigger_reason: :edited)

      expect(DiscourseIndexNow::SubmissionLog.pluck(:url)).to contain_exactly(topic.url)
      expect(DiscourseIndexNow::SubmissionLog.first.locale).to be_nil
    end

    # One batch of URLs, not one submission job per topic.
    it "collapses a whole category into a single submission batch" do
      4.times { Fabricate(:topic, category: category) }

      described_class.resubmit_topics(category_id: category.id)

      expect(DiscourseIndexNow::SubmissionLog.count).to eq(5)
      expect(DiscourseIndexNow::SubmissionLog.distinct.count(:batch_id)).to eq(1)
    end

    it "does nothing without a category or tag" do
      expect { described_class.resubmit_topics }.not_to change {
        DiscourseIndexNow::SubmissionLog.count
      }
    end
  end

  it "disables the plugin when login becomes required" do
    SiteSetting.login_required = true
    described_class.disable_if_login_required!

    expect(SiteSetting.indexnow_enabled).to eq(false)
  end
end
