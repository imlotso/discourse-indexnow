# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::LogFilter do
  it "interprets inclusive dates in the current application time zone" do
    first = DiscourseIndexNow::SubmissionLog.create!(url: "https://example.com/first", created_at: Time.utc(2026, 1, 11, 16, 30))
    last = DiscourseIndexNow::SubmissionLog.create!(url: "https://example.com/last", created_at: Time.utc(2026, 1, 12, 15, 30))
    outside = DiscourseIndexNow::SubmissionLog.create!(url: "https://example.com/outside", created_at: Time.utc(2026, 1, 12, 16, 30))

    Time.use_zone("Asia/Shanghai") do
      ids = described_class.new(since: "2026-01-12", until: "2026-01-12").apply.pluck(:id)
      expect(ids).to contain_exactly(first.id, last.id)
      expect(ids).not_to include(outside.id)
    end
  end
end
