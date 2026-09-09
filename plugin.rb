# frozen_string_literal: true

# name: discourse-indexnow
# about: Automatically submit new and edited topic URLs to IndexNow-compatible search engines.
# version: 0.2.2
# authors: sitetalk.net
# url: https://github.com/imlotso/discourse-indexnow

enabled_site_setting :indexnow_enabled

register_asset "stylesheets/admin.scss", :admin

module ::DiscourseIndexNow
  PLUGIN_NAME = "discourse-indexnow"
end

require_relative "lib/discourse_index_now/validators"
require_relative "config/routes"

add_admin_route "discourse_index_now.admin.title",
                "discourse-indexnow",
                use_new_show_route: true

after_initialize do
  require_relative "app/controllers/discourse_index_now/key_controller"
  require_relative "app/controllers/discourse_index_now/admin_logs_controller"
  require_relative "app/jobs/discourse_index_now/submit_batch"
  require_relative "app/jobs/discourse_index_now/check_key_accessibility"
  require_relative "app/jobs/discourse_index_now/resubmit_topics"
  require_relative "app/jobs/scheduled/discourse_index_now/recover_stalled_logs"
  require_relative "app/models/discourse_index_now/submission_log"
  require_relative "lib/discourse_index_now/client"
  require_relative "lib/discourse_index_now/eligibility"
  require_relative "lib/discourse_index_now/key_accessibility"
  require_relative "lib/discourse_index_now/throttle"
  require_relative "lib/discourse_index_now/url_builder"
  require_relative "lib/discourse_index_now/submission_service"

  add_model_callback(TopicLocalization, :after_commit, on: :create) do
    DiscourseIndexNow::SubmissionService.handle_topic_localization_created(self)
  end

  on(:post_created) { |post| DiscourseIndexNow::SubmissionService.handle_post_created(post) }

  on(:post_edited) do |post, topic_changed, _revisor|
    DiscourseIndexNow::SubmissionService.handle_post_edited(post, topic_changed)
  end

  on(:topic_category_changed) do |topic, _old_category|
    DiscourseIndexNow::SubmissionService.handle_topic_changed(topic)
  end

  on(:category_updated) do |category|
    DiscourseIndexNow::SubmissionService.handle_category_updated(category)
  end

  on(:tag_updated) do |tag|
    DiscourseIndexNow::SubmissionService.handle_tag_updated(tag)
  end

  on(:topic_destroyed) { |topic| DiscourseIndexNow::SubmissionService.handle_topic_destroyed(topic) }

  on(:site_setting_changed) do |name, _old_value, _new_value|
    next unless name.to_sym == :login_required

    DiscourseIndexNow::SubmissionService.disable_if_login_required!
  end
end
