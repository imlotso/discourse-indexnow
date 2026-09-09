// Adds the plugin's Logs page under core's adminPlugins.show route.
//
// Both the route NAME and the PATH have to be plugin-scoped, and the path is the
// one that actually bites. adminPlugins.show is mounted at /plugins/:plugin_id,
// so every plugin that adds a child here shares one namespace: a child with
// `path: "logs"` claims /admin/plugins/:plugin_id/logs for the whole site, not
// just for this plugin. When two installed plugins claim the same path, one of
// them silently loses its entire route map -- which is what happened here
// against discourse-sitemap-autolink, whose logs page also used `path: "logs"`.
//
// Hence "indexnow-logs" rather than "logs". The route name is likewise suffixed
// rather than being the bare plugin id, matching discourse-rss-polling-feeds and
// discourse-sitemap-autolink-overview.
//
// Discourse reads only `resource` and `map` here; `path` on this object is inert
// for a map targeting an existing resource, and is kept at the value core and the
// bundled plugins use so it does not read as meaningful config.
export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("discourse-indexnow-logs", { path: "indexnow-logs" });
  },
};
