# frozen_string_literal: true

Discourse::Application.routes.append do
  # Public key verification endpoint. IndexNow fetches https://<host>/<key>.txt and
  # expects the key back as plain text.
  #
  # The constraint must stay unanchored. Rails rejects \A / \z in routing
  # requirements ("Regexp anchor characters are not allowed in routing
  # requirements"), and because this block runs while the route table is being
  # drawn, an anchored constraint takes the whole application down at boot, not
  # just this route. A segment constraint is already bounded by the surrounding
  # "/" and ".txt" literals, so anchors buy nothing here.
  get "/:key.txt" => "discourse_index_now/key#show",
      constraints: {
        key: /[a-f0-9]{32}/,
      }

  # Full-page loads of the custom admin page (deep link, hard refresh, back
  # button). Core only routes /admin/plugins/:plugin_id and .../settings, so every
  # extra page in the plugin's admin nav needs its own Rails route that renders the
  # admin SPA shell. Core's admin/plugins#index does exactly that: check_xhr turns a
  # non-XHR HTML request into RenderEmpty, which renders the shell and lets Ember
  # take over routing. `format: false` keeps this from also matching the .json API
  # paths below.
  scope format: false, constraints: ::StaffConstraint.new do
    get "/admin/plugins/discourse-indexnow/indexnow-logs" => "admin/plugins#index"
  end

  # JSON management API.
  #
  # `defaults: { format: :json }` is load-bearing, not decoration. These actions
  # inherit Admin::AdminController, whose check_xhr filter answers any request that
  # neither asks for JSON nor is an XHR with the admin SPA HTML shell — before the
  # controller's own filters run. Without the default, curl, scripts, uptime checks
  # and anything else that sends `Accept: */*` get a full HTML page back with HTTP
  # 200 instead of data, and `requires_plugin` never gets the chance to refuse a
  # disabled plugin.
  scope "/admin/plugins/discourse-indexnow",
        module: "discourse_index_now",
        constraints: ::StaffConstraint.new,
        defaults: {
          format: :json,
        } do
    get "/logs.json" => "admin_logs#index"
    post "/generate_key.json" => "admin_logs#generate_key"
    get "/backfill/preview.json" => "admin_logs#backfill_preview"
    post "/backfill.json" => "admin_logs#backfill"
    post "/submit_urls.json" => "admin_logs#submit_urls"
    post "/cancel_pending.json" => "admin_logs#cancel_pending"
    delete "/logs.json" => "admin_logs#destroy_filtered"
  end
end
