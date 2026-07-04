# frozen_string_literal: true

# Milestone 4 Layer C — one-shot pickups. An overworld item ball is a SINGLE-use
# pickup (the map event sets a self-switch client-side so it can't be taken twice).
# A cheat can reset that self-switch (or save-edit) to re-pick-up and dupe the item.
# This append-only table records each account's validated pickups keyed by tile;
# the UNIQUE(account_id, map, x, y) index makes a second claim for the same tile a
# detectable duplicate. Detection-only for now (logged); enforcement (reject / server
# -mint) is a later slice. cascade on account delete; identity/audit-style.
Sequel.migration do
  change do
    create_table(:pickups) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Integer  :map, null: false
      Integer  :x,   null: false
      Integer  :y,   null: false
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[account_id map x y], unique: true, name: :pickups_dedup
    end
  end
end
