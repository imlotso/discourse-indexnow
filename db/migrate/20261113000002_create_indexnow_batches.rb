# frozen_string_literal: true

class CreateIndexnowBatches < ActiveRecord::Migration[7.2]
  def change
    create_table :indexnow_batches do |t|
      t.string :batch_id, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.jsonb :filters, null: false, default: {}
      t.bigint :cursor, null: false, default: 0
      t.bigint :snapshot_max_id
      t.integer :next_batch_index, null: false, default: 1
      t.bigint :matched_count, null: false, default: 0
      t.bigint :processed_count, null: false, default: 0
      t.bigint :queued_count, null: false, default: 0
      t.bigint :skipped_count, null: false, default: 0
      t.text :error_message
      t.timestamps
    end

    add_index :indexnow_batches, :batch_id, unique: true
  end
end
