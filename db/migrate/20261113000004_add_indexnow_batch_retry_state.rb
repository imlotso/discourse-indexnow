# frozen_string_literal: true

class AddIndexnowBatchRetryState < ActiveRecord::Migration[7.2]
  def change
    add_column :indexnow_batches, :generation_attempt_count, :integer, null: false, default: 0
    add_column :indexnow_batches, :retry_at, :datetime
  end
end
