# frozen_string_literal: true

require "rails_helper"

describe "Discourse IndexNow logs routes", type: :request do
  fab!(:admin)

  before do
    SiteSetting.indexnow_enabled = true
    SiteSetting.login_required = false
    allow(DiscourseIndexNow::KeyAccessibility).to receive(:check).and_return(true)
    sign_in(admin)
  end

  it "rejects log mutations for non-admin users" do
    sign_in(Fabricate(:user))

    expect {
      post "/admin/plugins/discourse-indexnow/cancel_pending.json"
    }.not_to change { DiscourseIndexNow::SubmissionLog.count }

    expect(response.status).to eq(404)
    expect(response.parsed_body["errors"]).to be_present

    expect {
      delete "/admin/plugins/discourse-indexnow/logs.json"
    }.not_to change { DiscourseIndexNow::SubmissionLog.count }

    expect(response.status).to eq(404)
  end

  it "renders the admin HTML shell for direct visits and hard refreshes" do
    get "/admin/plugins/discourse-indexnow/indexnow-logs"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("</html>")
  end

  # Regression: without `defaults: { format: :json }` on the API scope, check_xhr
  # answered any request that did not explicitly ask for JSON with the admin SPA
  # HTML shell and HTTP 200. curl, scripts and uptime checks got a whole HTML page
  # where they asked for data, and requires_plugin never ran.
  it "returns JSON to clients that do not ask for it explicitly" do
    get "/admin/plugins/discourse-indexnow/logs.json", headers: { "HTTP_ACCEPT" => "*/*" }

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("application/json")
    expect(response.body).not_to include("<html")
  end

  it "returns JSON from the explicit API path" do
    DiscourseIndexNow::SubmissionLog.create!(
      url: "https://forum.example.com/t/topic/1",
      batch_id: "batch-1",
      batch_index: 1,
      status: :pending,
    )

    get "/admin/plugins/discourse-indexnow/logs.json"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body["logs"].first["batch_id"]).to eq("batch-1")
  end
end
