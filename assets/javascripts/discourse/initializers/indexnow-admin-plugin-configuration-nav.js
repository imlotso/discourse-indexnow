import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-indexnow";
const LOGS_ROUTE = "adminPlugins.show.discourse-indexnow-logs";
const LOGS_URL = "/admin/plugins/discourse-indexnow/indexnow-logs";

/**
 * Registers the plugin's "Logs" tab in the admin plugin nav, but only once the
 * router confirms the route behind it is really there.
 *
 * Core's adminPlugins.show.index route calls replaceWith() on the first
 * non-settings entry in a plugin's config nav, unconditionally. A nav entry
 * whose route is missing is therefore not a missing tab: it throws "There is no
 * route named ..." on every visit to the plugin's admin page, Ember retries, and
 * with a theme that renders site chrome in an outlet the retries stack headers
 * until the browser tab runs out of memory.
 *
 * The route can be missing even when its route map module has loaded. mapRoutes()
 * resolves `resource: "admin.adminPlugins.show"` through tree.findPath() and, if
 * that node is not in the tree at the moment routes are mapped, drops the map
 * with no error at all:
 *
 *     extras.forEach((extra) => {
 *       let node = tree.findPath(extra.resource);
 *       if (node) { node.extract(extra.map); }
 *     });
 *
 * so registration cannot be assumed to have worked. The check has to be deferred:
 * at instance-initializer time the router is not set up yet and hasRoute() throws.
 *
 * It also has to be retried rather than made once. Admin routes live in a chunk
 * that is loaded separately, so on a boot that starts outside the admin panel the
 * first transition can resolve this URL to core's catch-all simply because those
 * routes are not in the recognizer yet. Checking once and giving up leaves the tab
 * permanently missing on a working site. So both edges of a transition are
 * watched, and the listeners stay attached until the route actually resolves.
 */
export default {
  name: "indexnow-admin-plugin-configuration-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    const router = container.lookup("service:router");
    if (!router) {
      return;
    }

    const register = () => {
      // Keep listening until the route resolves; admin routes may arrive later.
      if (!this.routeExists(router)) {
        return;
      }

      router.off("routeWillChange", register);
      router.off("routeDidChange", register);

      withPluginApi((api) => {
        api.addAdminPluginConfigurationNav(PLUGIN_ID, [
          {
            label: "discourse_index_now.admin.logs",
            route: LOGS_ROUTE,
          },
        ]);
      });
    };

    router.on("routeWillChange", register);
    router.on("routeDidChange", register);
  },

  /**
   * True when the router actually resolves the logs URL to the logs route.
   *
   * recognize() is the public equivalent of asking the router whether a route
   * exists; when the route map was dropped the URL falls through to core's
   * catch-all instead, and the name will not match. Anything unexpected counts as
   * absent: failing to advertise a tab is recoverable, advertising a missing one
   * is not.
   */
  routeExists(router) {
    try {
      return router.recognize(getURL(LOGS_URL))?.name === LOGS_ROUTE;
    } catch {
      return false;
    }
  },
};
