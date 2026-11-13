# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseIndexNow::ResumeQueued do
  it "wakes due batches when both limits are positive" do
    SiteSetting.indexnow_enabled = true
    SiteSetting.indexnow_hourly_limit = 10
    SiteSetting.indexnow_daily_limit = 10
    DiscourseIndexNow::SubmissionLog.create!(url: "https://example.com/a", batch_id: "due", batch_index: 1)
    DiscourseIndexNow::SubmissionLog.create!(
      url: "https://example.com/b",
      batch_id: "later",
      batch_index: 1,
      status: :retrying,
      available_at: 1.hour.from_now,
    )
    allow(Jobs).to receive(:enqueue)

    described_class.new.execute({})

    expect(Jobs).to have_received(:enqueue).with(
      Jobs::DiscourseIndexNow::SubmitBatch,
      batch_id: "due",
      batch_index: 1,
    ).once
    expect(Jobs).not_to have_received(:enqueue).with(
      Jobs::DiscourseIndexNow::SubmitBatch,
      batch_id: "later",
      batch_index: 1,
    )
  end
end
