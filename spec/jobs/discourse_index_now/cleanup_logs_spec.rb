# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseIndexNow::CleanupLogs do
  let(:model) { DiscourseIndexNow::SubmissionLog }

  it "keeps all logs when retention is disabled" do
    SiteSetting.indexnow_log_retention_days = 0
    log = model.create!(url: "https://example.com/a", status: :success)
    log.update_columns(updated_at: 90.days.ago)

    described_class.new.execute

    expect(model.exists?(log.id)).to eq(true)
  end

  it "removes only old terminal logs and keeps active and recent work" do
    SiteSetting.indexnow_log_retention_days = 30
    old = %i[success failed cancelled pending processing retrying].map do |status|
      log = model.create!(url: "https://example.com/#{status}", status: status)
      log.update_columns(updated_at: 31.days.ago)
      log
    end
    recent = model.create!(url: "https://example.com/recent", status: :success)

    described_class.new.execute

    expect(model.where(id: old.first(3).map(&:id)).count).to eq(0)
    expect(model.where(id: old.last(3).map(&:id)).count).to eq(3)
    expect(model.exists?(recent.id)).to eq(true)
  end
end
