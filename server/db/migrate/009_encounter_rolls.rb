# frozen_string_literal: true

# Milestone 4 Layer D D3 part 2 — persisted wild-encounter mints + mon provenance.
#
# encounter_rolls: every server-minted wild encounter (D2 `on`), one row per roll —
# the durable record of "the server issued THIS identity {species, level, pid, iv,
# shiny} to THIS account". caught_at is stamped when the D3 catch verdict grants the
# capture; claimed_at when the caught mon's UID mint (M3 :uid_req) claims the roll.
# Append-only claim-check data (not identity): cascade on account delete, like pickups.
# The (account_id, pid) index is the claim lookup; NOT unique — pid collisions across
# rolls are theoretically possible and harmless (claim takes the oldest unclaimed).
#
# monsters.origin (additive, existing rows stay NULL = legacy/unknown): provenance of
# the minted identity — "wild_caught" (matches a roll with a catch verdict), "wild"
# (matches a roll, no verdict — e.g. catches enforcement off), "client" (no matching
# roll: starters, gifts, eggs, event mons — all legitimately client-generated, which is
# why a missing roll can NEVER reject a mint). Detection/telemetry now; the foundation
# for ranked provenance gating later.
Sequel.migration do
  change do
    create_table(:encounter_rolls) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :species, null: false
      Integer  :level,   null: false
      Bignum   :pid,     null: false            # 32-bit personalID (fits comfortably)
      column   :iv, :jsonb, null: false          # [hp, atk, def, spa, spd, spe]
      TrueClass :shiny, null: false, default: false
      Integer  :map,     null: false
      String   :enctype, null: false
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :caught_at,  null: true           # set by the D3 catch verdict (caught)
      DateTime :claimed_at, null: true           # set when a UID mint claims this roll

      index %i[account_id pid], name: :encounter_rolls_claim
    end

    alter_table(:monsters) do
      add_column :origin, String, null: true     # wild_caught | wild | client | NULL(legacy)
    end
  end
end
