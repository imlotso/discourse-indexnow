# frozen_string_literal: true

module DiscourseIndexNow
  class SubmissionLog < ActiveRecord::Base
    self.table_name = "indexnow_submission_logs"

    enum :status, {
      pending: 0,
      success: 1,
      failed: 2,
      cancelled: 3,
    }

    enum :trigger_reason, {
      created: 0,
      edited: 1,
      deleted: 2,
      category_changed: 3,
      backfill: 4,
      manual: 5,
      replied: 6,
    }

    validates :url, presence: true
    validates :batch_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :locale, length: { maximum: 20 }, allow_nil: true
  end
end

# == Schema Information
#
# Table name: indexnow_submission_logs
#
#  id             :bigint           not null, primary key
#  batch_index    :integer          default(0), not null
#  error_message  :text
#  locale         :string(20)
#  response_code  :integer
#  status         :integer          default("pending"), not null
#  trigger_reason :integer          default("created"), not null
#  url            :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  batch_id       :string
#
# Indexes
#
#  index_indexnow_submission_logs_on_batch_id                  (batch_id)
#  index_indexnow_submission_logs_on_batch_id_and_batch_index  (batch_id,batch_index)
#  index_indexnow_submission_logs_on_created_at                (created_at)
#  index_indexnow_submission_logs_on_status                    (status)
#  index_indexnow_submission_logs_on_trigger_reason            (trigger_reason)
#  index_indexnow_submission_logs_on_url                       (url)
#
