# frozen_string_literal: true

# Milestone 3.1 — server-issued monster UIDs. `monsters` is the IDENTITY registry:
# one row per Pokémon instance a player owns; monsters.id (bigserial, never reused)
# IS the uid and survives evolution/hatching/nickname/trade — species/level/pid/egg
# are at-issue AUDIT snapshots only, allowed to go stale.
#
# Mint idempotency is the UNIQUE index on (issuer_account_id, client_nonce): the
# client persists a random per-instance nonce ivar in its save BEFORE requesting,
# so a re-sent uid_req (reconnect, lost grant, crash-after-save) re-finds the SAME
# uid — a duplicate mint is structurally impossible, not protocol discipline.
# NOTE: keyed to the IMMUTABLE issuer, never the mutable owner, so an M3.2 trade
# (UPDATE owner_account_id) can never reopen a mint window or collide nonces.
# (A deterministic personalID+timeReceived key was rejected: core mutates
# timeReceived after creation — Mystery Gift, 024_UI_MysteryGift.rb:377.)
#
# M3.2 trading is one CAS, zero DDL rework:
#   UPDATE monsters SET owner_account_id=:buyer, updated_at=now()
#    WHERE id=:uid AND owner_account_id=:seller AND status='active'
# ('traded' is deliberately NOT a status — ownership just moves; the append-only
# monster_transfers audit table arrives with its writer in M3.2.)
#
# flagged/flags are the dupe-detection surface (a uid projected by a non-owner
# account appends a sighting). DETECTION-ONLY in M3.1: flag, never reject.
# DELIBERATE divergence from inventory_snapshots: NO on_delete cascade on the
# monsters account FKs — identity/audit rows must survive account deletion.
#
# `party_snapshots` mirrors inventory_snapshots exactly (absolute jsonb snapshot,
# last_seq high-water, flag-never-reject; jsonb object keys are STRINGS) and
# becomes the M3.3 party-restore source.
Sequel.migration do
  change do
    create_table(:monsters) do
      primary_key :id, type: :Bignum                                        # THE server-issued UID
      foreign_key :owner_account_id,  :accounts, type: :Bignum, null: false # CURRENT owner — the only column M3.2 trading mutates
      foreign_key :issuer_account_id, :accounts, type: :Bignum, null: false # IMMUTABLE minting account (idempotency scope + provenance)
      Bignum      :client_nonce,   null: false                              # persisted per-instance client nonce
      String      :species,        null: false                              # Symbol#to_s verbatim (headless — never interpreted)
      Integer     :level_at_issue, null: false
      Bignum      :personal_id,    null: false                              # client @personalID at issue — audit/correlation ONLY, never a key
      TrueClass   :egg_at_issue,   null: false, default: false              # uid survives hatching (same Ruby object)
      String      :status,         null: false, default: "active"           # active | released | revoked (reserved; 'traded' is NOT a status)
      TrueClass   :flagged,        null: false, default: false              # dupe-detection operator surface
      column      :flags,          :jsonb, null: false, default: Sequel.lit("'[]'::jsonb") # [{"seen_by":N,"at":ts,"kind":"foreign_uid"},...]
      DateTime    :created_at,     null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime    :updated_at,     null: false, default: Sequel::CURRENT_TIMESTAMP

      index %i[issuer_account_id client_nonce], unique: true, name: :monsters_mint_dedup # the load-bearing index
      index :owner_account_id                                               # trade checks / "all mons of account X"
      index :flagged                                                        # operator: SELECT ... WHERE flagged
    end

    create_table(:party_snapshots) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade # disposable shadow — cascade OK here
      column      :party,      :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")    # [{"uid":4207|null,"species":"PIKACHU","level":12},...]
      Bignum      :last_seq,   null: false, default: 0                      # :mon channel high-water
      TrueClass   :flagged,    null: false, default: false
      column      :flags,      :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      DateTime    :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      primary_key [:account_id]                                             # one party shadow per account (mirrors inventory_snapshots)
    end
  end
end
