# frozen_string_literal: true

# Milestone 2.3 — server-side BAG record (DETECTION-ONLY). One materialized ABSOLUTE
# snapshot per account: the whole bag as {item_id_str => qty} in a jsonb column, the
# exact analogue of the materialized economy_balances row (one upsert per flush via
# insert_conflict on account_id). A per-account :inv seq high-water dedups replays —
# an absolute snapshot is idempotent by nature, so unlike economy_ledger no
# per-(account,field,seq) idempotency table is needed. The server RECORDS and
# structurally FLAGS anomalies but NEVER rejects: it cannot validate item ACQUISITION
# without a GameData::Item registry and server-side gameplay (M3). Denormalized
# distinct_items/total_qty/flagged/flags let an operator SELECT flagged accounts
# without parsing jsonb. M3 trading read-modify-writes this jsonb row under the
# PlayerMailbox lock (or backfills it to per-item rows in one pass) — no rewrite.
#
# NOTE: Postgres jsonb OBJECT KEYS ARE STRINGS — the store writes ids with :to_s and
# reads back with transform_keys(&:to_sym) so the client keeps Symbol keys.
Sequel.migration do
  change do
    create_table(:inventory_snapshots) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      column      :bag,            :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      Bignum      :last_seq,       null: false, default: 0
      Integer     :distinct_items, null: false, default: 0
      Bignum      :total_qty,      null: false, default: 0
      TrueClass   :flagged,        null: false, default: false
      column      :flags,          :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      DateTime    :updated_at,     null: false, default: Sequel::CURRENT_TIMESTAMP
      primary_key [:account_id]     # one bag per account (mirrors economy_balances/characters)
    end
  end
end
