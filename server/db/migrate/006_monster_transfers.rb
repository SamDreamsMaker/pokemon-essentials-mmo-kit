# frozen_string_literal: true

# Milestone 3.2 — server-authoritative trading. Append-only audit of every UID
# ownership transfer AND the idempotency anchor for the atomic swap. NO change to
# migration 005: a trade just moves monsters.owner_account_id ('traded' is
# deliberately NOT a status). The UNIQUE(trade_id, uid) index makes a replayed
# swap a no-op (the execute_trade transaction checks trade_id first, and the index
# is the belt-and-braces). NO on_delete cascade on the FKs — identity/audit rows
# outlive accounts and mons (matches 005's monsters FK stance).
Sequel.migration do
  change do
    create_table(:monster_transfers) do
      primary_key :id, type: :Bignum
      foreign_key :uid,             :monsters, type: :Bignum, null: false
      foreign_key :from_account_id, :accounts, type: :Bignum, null: false
      foreign_key :to_account_id,   :accounts, type: :Bignum, null: false
      String      :trade_id,        null: false                       # rendezvous id + replay/idempotency key
      DateTime    :created_at,      null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[trade_id uid], unique: true, name: :monster_transfers_dedup
      index :trade_id
      index :from_account_id                                          # reconcile_block evictions() lookup
      index :uid
    end
  end
end
