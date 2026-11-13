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

  it "aligns Chinese filters and backfill actions on desktop" do
    SiteSetting.allow_user_locale = true
    admin.update!(locale: "zh_CN")
    dark_scheme = ColorScheme.find_by!(base_scheme_id: ColorScheme::NAMES_TO_ID_MAP["Dark"])
    Theme.find_default.update!(color_scheme_id: dark_scheme.id)
    DiscourseIndexNow::SubmissionLog.create!(
      url: "#{Discourse.base_url}/t/#{'long-topic-' * 20}/1",
      status: :success,
      response_code: 200,
      batch_id: SecureRandom.uuid,
    )
    sign_in(admin)
    resize_window(width: 1280, height: 1000) do
      visit "/admin/plugins/discourse-indexnow/indexnow-logs"
      expect(page).to have_css("#indexnow-filter-url")

      geometry = page.evaluate_script(<<~JS)
        (() => {
          const rect = (selector) => document.querySelector(selector).getBoundingClientRect();
          const url = rect('#indexnow-filter-url');
          const batch = rect('#indexnow-filter-batch');
          const date = rect('input#indexnow-backfill-until');
          const submit = rect('.indexnow-submit-backfill');
          const fieldsFit = [...document.querySelectorAll('.indexnow-field input, .indexnow-field select')].every(input => {
            const field = input.closest('.indexnow-field').getBoundingClientRect();
            const control = input.getBoundingClientRect();
            return control.left >= field.left - 1 && control.right <= field.right + 1;
          });
          const headersFit = [...document.querySelectorAll('.indexnow-log-table th')].every(header => {
            const text = document.createRange();
            text.selectNodeContents(header);
            const style = getComputedStyle(header);
            const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.5;
            return text.getBoundingClientRect().height <= lineHeight + 1;
          });
          return { filterOffset: Math.abs(url.top - batch.top), actionOffset: Math.abs(date.bottom - submit.bottom), fieldsFit, headersFit };
        })()
      JS

      aggregate_failures do
        expect(geometry["filterOffset"]).to be <= 2
        expect(geometry["actionOffset"]).to be <= 2
        expect(geometry["fieldsFit"]).to eq(true)
        expect(geometry["headersFit"]).to eq(true)
      end
    end
  end

  it "keeps the table scrollable without widening a tablet page" do
    sign_in(admin)
    resize_window(width: 800, height: 1000) do
      visit "/admin/plugins/discourse-indexnow/indexnow-logs"
      expect(page).to have_css(".indexnow-log-table")
      expect(page.evaluate_script("window.innerWidth")).to eq(800)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1")).to eq(true)

      find(".indexnow-log-table-container").send_keys(:right)
      expect(page).to have_css(".indexnow-log-table-container:focus")
      page.driver.with_playwright_page do |browser|
        browser.wait_for_function("document.querySelector('.indexnow-log-table-container').scrollLeft > 0")
      end
    end
  end

  it "keeps long failure details and retry controls inside a phone layout", mobile: true do
    SiteSetting.allow_user_locale = true
    admin.update!(locale: "zh_CN")
    DiscourseIndexNow::SubmissionLog.create!(
      url: "#{Discourse.base_url}/t/#{'long-topic-' * 20}/1?tl=zh_CN",
      status: :failed,
      response_code: 403,
      error_message: "network-error-" * 30,
      batch_id: SecureRandom.uuid,
    )
    sign_in(admin)
    visit "/admin/plugins/discourse-indexnow/indexnow-logs"
    expect(page).to have_css(".indexnow-retry-one")

    [390, 320].each do |width|
      page.driver.with_playwright_page { |browser| browser.set_viewport_size(width: width, height: 1000) }
      page.execute_script("document.documentElement.style.fontSize = '20px'") if width == 320
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const url = document.querySelector('.indexnow-log-table .--overview').getBoundingClientRect();
          const retry = document.querySelector('.indexnow-retry-one').getBoundingClientRect();
          return { retryBelowUrl: retry.top >= url.bottom, fits: document.documentElement.scrollWidth <= window.innerWidth + 1 };
        })()
      JS

      expect(geometry["retryBelowUrl"]).to eq(true)
      expect(geometry["fits"]).to eq(true)
    end
  end
end
