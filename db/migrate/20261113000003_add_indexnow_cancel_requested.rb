# frozen_string_literal: true

class AddIndexnowCancelRequested < ActiveRecord::Migration[7.2]
  def change
    add_column :indexnow_submission_logs, :cancel_requested, :boolean, null: false, default: false
  end
end
