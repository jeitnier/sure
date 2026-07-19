class CreateAssistantProposals < ActiveRecord::Migration[7.2]
  def change
    create_table :assistant_proposals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid, index: true
      t.references :chat, null: false, foreign_key: true, type: :uuid
      t.references :message, foreign_key: true, type: :uuid
      t.string :kind, null: false
      t.jsonb :params, null: false, default: {}
      t.jsonb :preview, null: false, default: {}
      t.jsonb :changes_journal, null: false, default: {}
      t.string :status, null: false, default: "proposed"
      t.datetime :applied_at
      t.datetime :undone_at
      t.text :error
      t.timestamps
    end
    add_index :assistant_proposals, [ :family_id, :status ]
  end
end
