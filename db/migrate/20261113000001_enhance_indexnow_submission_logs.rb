# frozen_string_literal: true

class EnhanceIndexnowSubmissionLogs < ActiveRecord::Migration[7.2]
  def up
    add_column :indexnow_submission_logs, :topic_id, :bigint
    add_column :indexnow_submission_logs, :retry_of_id, :bigint
    add_column :indexnow_submission_logs, :attempt_count, :integer, null: false, default: 0
    add_column :indexnow_submission_logs, :claimed_at, :datetime
    add_column :indexnow_submission_logs, :claim_token, :string
    add_column :indexnow_submission_logs, :available_at, :datetime
    add_index :indexnow_submission_logs, %i[topic_id status]
    add_index :indexnow_submission_logs, %i[status available_at]

    replace_status_constraint("0, 1, 2, 3, 4, 5")
  end

  def down
    Migration::SafeMigrate.disable! if defined?(Migration::SafeMigrate)
    # Keep outstanding work rather than deleting rows when reverting.
    execute "UPDATE indexnow_submission_logs SET status = 0 WHERE status IN (4, 5)"
    change_status_constraint("0, 1, 2, 3")

    remove_index :indexnow_submission_logs, %i[status available_at]
    remove_index :indexnow_submission_logs, %i[topic_id status]
    remove_column :indexnow_submission_logs, :available_at
    remove_column :indexnow_submission_logs, :claim_token
    remove_column :indexnow_submission_logs, :claimed_at
    remove_column :indexnow_submission_logs, :attempt_count
    remove_column :indexnow_submission_logs, :retry_of_id
    remove_column :indexnow_submission_logs, :topic_id
  ensure
    Migration::SafeMigrate.enable! if defined?(Migration::SafeMigrate)
  end

  private

  def replace_status_constraint(values)
    # Discourse's migration guard treats any DROP CONSTRAINT as a column drop.
    # This only replaces a check constraint, in the migration transaction.
    Migration::SafeMigrate.disable! if defined?(Migration::SafeMigrate)
    change_status_constraint(values)
  ensure
    Migration::SafeMigrate.enable! if defined?(Migration::SafeMigrate)
  end

  def change_status_constraint(values)
    execute "ALTER TABLE indexnow_submission_logs DROP CONSTRAINT IF EXISTS indexnow_submission_logs_status_check"
    execute <<~SQL
      ALTER TABLE indexnow_submission_logs
      ADD CONSTRAINT indexnow_submission_logs_status_check
      CHECK (status IN (#{values}))
    SQL
  end
end
