# frozen_string_literal: true

require "rails_helper"

describe ::DiscourseIndexNow do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.login_required = false
    SiteSetting.indexnow_enabled = true
  end

  after { SiteSetting.login_required = false }

  it "automatically disables IndexNow when login becomes required" do
    SiteSetting.login_required = true

    expect(SiteSetting.indexnow_enabled).to eq(false)
  end

  it "does not automatically re-enable IndexNow when login becomes optional" do
    SiteSetting.indexnow_enabled = false
    SiteSetting.login_required = true
    SiteSetting.login_required = false

    expect(SiteSetting.indexnow_enabled).to eq(false)
  end

  it "listens for category changes on a topic" do
    allow(DiscourseIndexNow::SubmissionService).to receive(:handle_topic_changed)
    DiscourseEvent.trigger(:topic_category_changed, topic, category)

    expect(DiscourseIndexNow::SubmissionService).to have_received(:handle_topic_changed).with(topic)
  end

  it "listens for category visibility updates" do
    allow(DiscourseIndexNow::SubmissionService).to receive(:handle_category_updated)
    DiscourseEvent.trigger(:category_updated, category)

    expect(DiscourseIndexNow::SubmissionService).to have_received(:handle_category_updated).with(
      category,
    )
  end

  it "listens for tag updates" do
    tag = Fabricate(:tag)
    allow(DiscourseIndexNow::SubmissionService).to receive(:handle_tag_updated)
    DiscourseEvent.trigger(:tag_updated, tag)

    expect(DiscourseIndexNow::SubmissionService).to have_received(:handle_tag_updated).with(tag)
  end

  it "passes topic_changed to post edit handling" do
    allow(DiscourseIndexNow::SubmissionService).to receive(:handle_post_edited)
    revisor = double(topic_diff: {})
    DiscourseEvent.trigger(:post_edited, post, true, revisor)

    expect(DiscourseIndexNow::SubmissionService).to have_received(:handle_post_edited).with(
      post,
      true,
    )
  end

  it "submits a topic localization when it is created" do
    allow(DiscourseIndexNow::SubmissionService).to receive(:handle_topic_localization_created)
    localization = Fabricate(:topic_localization, topic: topic, locale: "en")

    expect(DiscourseIndexNow::SubmissionService).to have_received(
      :handle_topic_localization_created,
    ).with(localization)
  end

  it "publishes the finalized plugin metadata" do
    header = File.read(Rails.root.join("plugins/discourse-indexnow/plugin.rb"))

    expect(header).to include("# version: 0.2.2")
    expect(header).to include("# authors: sitetalk.net")
    expect(header).to include("# url: https://github.com/imlotso/discourse-indexnow")
  end

  MAIN_BUNDLE = "plugins/discourse-indexnow/assets/javascripts/discourse"

  it "nests the logs route under core's adminPlugins.show resource" do
    route_map = File.read(Rails.root.join("#{MAIN_BUNDLE}/admin-indexnow-route-map.js"))

    # Discourse reads only `resource` and `map` from a route map aimed at an
    # existing resource (mapRoutes in frontend/discourse/app/mapping-router.js
    # looks up `extra.resource` and calls `extra.map`); `path` is inert here.
    expect(route_map).to include('resource: "admin.adminPlugins.show"')
    expect(route_map).to include('this.route("discourse-indexnow-logs", { path: "indexnow-logs" })')
  end

  # adminPlugins.show is mounted at /plugins/:plugin_id, so a child route's path is
  # claimed across the whole site rather than per plugin: `path: "logs"` matches
  # /admin/plugins/ANY_PLUGIN/logs. When two installed plugins claim the same path
  # the loser's route is dropped, which is what happened against
  # discourse-sitemap-autolink (whose logs page also used `path: "logs"`) --
  # IndexNow's route vanished and core then replaceWith()'d a route that no longer
  # existed. Both the path and the route name have to be plugin-scoped.
  it "scopes the child route path so it cannot collide with another plugin" do
    route_map = File.read(Rails.root.join("#{MAIN_BUNDLE}/admin-indexnow-route-map.js"))

    # Match the route call, not prose: the comment above it quotes `path: "logs"`
    # as the thing being avoided.
    expect(route_map).to match(/this\.route\("discourse-indexnow-logs", \{ path: "indexnow-logs" \}\)/)
    expect(route_map).not_to match(/this\.route\([^)]*\{ path: "logs" \}\)/)
  end

  it "does not name the child route after the plugin id" do
    route_map = File.read(Rails.root.join("#{MAIN_BUNDLE}/admin-indexnow-route-map.js"))

    expect(route_map).not_to include('this.route("discourse-indexnow"')
  end

  # Core replaceWith()s the first non-settings nav entry unconditionally, so a nav
  # entry whose route is missing throws on every visit to the plugin's admin page
  # and Ember retries, growing the DOM until the browser tab dies. mapRoutes()
  # drops a `resource:` map silently when tree.findPath("admin.adminPlugins.show")
  # misses, so registration cannot be assumed to have worked: the initializer has
  # to confirm the route resolves before advertising a tab for it.
  it "only advertises the logs tab once the router resolves the route" do
    initializer =
      File.read(
        Rails.root.join("#{MAIN_BUNDLE}/initializers/indexnow-admin-plugin-configuration-nav.js"),
      )

    expect(initializer).to include("routeExists")
    expect(initializer).to include("recognize")
    expect(initializer).to include("routeWillChange")
  end

  # Both files ship in the main bundle, matching discourse-rss-polling and
  # discourse-sitemap-autolink.
  it "ships the route map and nav entry where the other plugins do" do
    expect(Rails.root.join("#{MAIN_BUNDLE}/admin-indexnow-route-map.js")).to exist
    expect(
      Rails.root.join("#{MAIN_BUNDLE}/initializers/indexnow-admin-plugin-configuration-nav.js"),
    ).to exist
  end

  # Replacing a key is destructive out of band: the old one dies immediately and
  # IndexNow answers 202 ("key validation pending") until it re-fetches
  # /<key>.txt, dropping those URLs if validation fails. Rotation stays possible,
  # but it asks first rather than firing on a stray click.
  it "confirms before replacing an existing key" do
    controller =
      File.read(
        Rails.root.join(
          "plugins/discourse-indexnow/admin/assets/javascripts/discourse/controllers/admin-plugins/show/discourse-indexnow-logs.js",
        ),
      )

    expect(controller).to include("deleteConfirm")
    expect(controller).to include("discourse_index_now.admin.generate_key_confirm")
    # ...and skips the prompt when there is no key to lose.
    expect(controller).to match(/if \(!this\.stats\.api_key\)/)
  end

  it "keeps the admin stylesheet out of the public forum bundle" do
    header = File.read(Rails.root.join("plugins/discourse-indexnow/plugin.rb"))

    # Without the :admin scope this stylesheet is linked on every forum page for
    # every visitor, not just the admin panel.
    expect(header).to include('register_asset "stylesheets/admin.scss", :admin')
  end

  # A key referenced from JS but missing from the locale renders as the literal
  # "[en.js.discourse_index_now.admin.whatever]" in the admin panel, which no
  # test caught until it was noticed by eye. Both shipped locales are checked,
  # so an English-only addition fails here rather than on a zh_CN forum.
  it "ships every admin translation the frontend asks for" do
    root = Rails.root.join("plugins/discourse-indexnow")

    referenced =
      Dir[root.join("{admin/assets,assets}/javascripts/**/*.{js,gjs}")]
        .flat_map do |path|
          # Greedy capture plus the lookahead skips interpolated keys such as
          # `discourse_index_now.admin.status_${log.status}` outright, rather
          # than recording the "status_" prefix as a key of its own.
          File.read(path).scan(/discourse_index_now\.admin\.([a-z0-9_]+)(?![a-z0-9_$])/)
        end
        .flatten
        .uniq

    expect(referenced).to include("quota_hourly", "quota_count", "quota_frees_in")

    %w[en zh_CN].each do |locale|
      translations =
        YAML.load_file(root.join("config/locales/client.#{locale}.yml")).dig(
          locale,
          "js",
          "discourse_index_now",
          "admin",
        )

      expect(translations.keys).to include(*referenced), "missing #{locale} keys: " \
        "#{(referenced - translations.keys).join(', ')}"
    end
  end
end
