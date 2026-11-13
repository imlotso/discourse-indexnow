# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("plugins/discourse-indexnow/db/migrate/20261113000001_enhance_indexnow_submission_logs.rb")

describe EnhanceIndexnowSubmissionLogs do
  it "preserves old pending and failed rows while allowing the new queue states" do
    migration = described_class.new
    migration.down
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      INSERT INTO indexnow_submission_logs (url, status, created_at, updated_at)
      VALUES ('https://example.com/pending', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
             ('https://example.com/failed', 2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL

    migration.up
    DiscourseIndexNow::SubmissionLog.reset_column_information
    expect(DiscourseIndexNow::SubmissionLog.find_by!(url: "https://example.com/pending")).to be_pending
    expect(DiscourseIndexNow::SubmissionLog.find_by!(url: "https://example.com/failed")).to be_failed
    expect { DiscourseIndexNow::SubmissionLog.create!(url: "https://example.com/running", status: :processing) }.not_to raise_error
    expect { DiscourseIndexNow::SubmissionLog.create!(url: "https://example.com/retrying", status: :retrying) }.not_to raise_error
  ensure
    Migration::SafeMigrate.disable! if defined?(Migration::SafeMigrate)
    DiscourseIndexNow::SubmissionLog.reset_column_information
  end
end
