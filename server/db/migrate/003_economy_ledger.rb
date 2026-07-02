# frozen_string_literal: true

# Milestone 2.1 — server-authoritative economy. A materialized balance per
# (account, field) for O(1) reads + reconciliation, and an append-only ledger that
# doubles as the per-(account,field,seq) idempotency key (row existence = already
# applied, gap-safe — never a high-water compare). save_seq makes the opaque blob
# push idempotent (reject a stale/replayed save).
Sequel.migration do
  change do
    create_table(:economy_balances) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String      :field,    null: false
      Bignum      :balance,  null: false, default: 0
      Bignum      :last_seq, null: false, default: 0
      primary_key [:account_id, :field]
    end

    create_table(:economy_ledger) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String      :field,         null: false
      Bignum      :delta,         null: false
      String      :reason,        null: false, default: "unattributed"
      Bignum      :seq,           null: false
      Bignum      :balance_after, null: false
      DateTime    :created_at,    null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[account_id field seq], unique: true, name: :economy_ledger_dedup
    end

    alter_table(:characters) do
      add_column :save_seq, :Bignum, null: false, default: 0
    end
  end
end
