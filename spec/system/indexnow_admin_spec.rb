# frozen_string_literal: true

RSpec.describe "IndexNow administration" do
  fab!(:admin)

  before do
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_api_key = "a" * 32
    allow(DiscourseIndexNow::KeyAccessibility).to receive(:check).and_return(true)
  end

  it "opens the logs directly and survives a browser refresh" do
    sign_in(admin)
    visit "/admin/plugins/discourse-indexnow/indexnow-logs"

    expect(page).to have_css(".indexnow-indexing-note")
    page.refresh
    expect(page).to have_css(".indexnow-indexing-note")
    expect(page).to have_content("does not guarantee crawling or indexing")
  end

  it "keeps the filters usable with a narrow viewport and keyboard", mobile: true do
    sign_in(admin)
    DiscourseIndexNow::SubmissionLog.create!(
      url: "#{Discourse.base_url}/t/#{'long-topic-' * 20}/1",
      status: :success,
      response_code: 202,
    )
    visit "/admin/plugins/discourse-indexnow/indexnow-logs"

    expect(page.evaluate_script("window.innerWidth")).to be <= 390
    expect(page).to have_css('label[for="indexnow-backfill-since"]')
    expect(page).to have_css("input#indexnow-backfill-since")
    expect(page).to have_css('.indexnow-status-filters [aria-pressed="true"]', count: 1)
    expect(page).to have_content("key validation was pending")
    find("#indexnow-filter-response").click
    page.active_element.send_keys(:tab)
    expect(page).to have_css("#indexnow-filter-locale:focus")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1")).to eq(true)
  end

  it "renders the simplified Chinese submission explanation" do
    SiteSetting.allow_user_locale = true
    admin.update!(locale: "zh_CN")
    sign_in(admin)
    visit "/admin/plugins/discourse-indexnow/indexnow-logs"

    expect(page).to have_content("引擎接收提交不代表已抓取或收录")
  end
end
