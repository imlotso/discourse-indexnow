# frozen_string_literal: true

module DiscourseIndexNow
  class Batch < ActiveRecord::Base
    self.table_name = "indexnow_batches"

    validates :batch_id, presence: true, uniqueness: true
    validates :kind, inclusion: { in: %w[backfill retry] }
    validates :status, inclusion: { in: %w[queued running generated cancelled failed] }

    def display_status
      return status unless status == "generated"

      active = SubmissionLog.where(batch_id: batch_id, status: %i[pending processing retrying]).exists?
      active ? "running" : "completed"
    end
  end
end

# == Schema Information
#
# Table name: indexnow_batches
#
#  id                       :bigint           not null, primary key
#  cursor                   :bigint           default(0), not null
#  error_message            :text
#  filters                  :jsonb            not null
#  generation_attempt_count :integer          default(0), not null
#  kind                     :string           not null
#  matched_count            :bigint           default(0), not null
#  next_batch_index         :integer          default(1), not null
#  processed_count          :bigint           default(0), not null
#  queued_count             :bigint           default(0), not null
#  retry_at                 :datetime
#  skipped_count            :bigint           default(0), not null
#  status                   :string           default("queued"), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  batch_id                 :string           not null
#  snapshot_max_id          :bigint
#
# Indexes
#
#  index_indexnow_batches_on_batch_id  (batch_id) UNIQUE
#
