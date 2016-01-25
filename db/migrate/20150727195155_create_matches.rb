class CreateMatches < ActiveRecord::Migration
  def change
    create_table :matches do |t|
      t.references :user, index: true, foreign_key: true
      t.references :matched_user, index: true

      t.timestamps
    end

    add_index :matches, [:user_id, :matched_user_id], unique: true
    add_foreign_key :matches, :users, column: :matched_user_id
  end
end
