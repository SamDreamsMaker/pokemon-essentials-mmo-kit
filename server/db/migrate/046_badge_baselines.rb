# frozen_string_literal: true

# Badge authority B1 (docs/BADGE-AUTHORITY-DESIGN.md): each account's badges as the
# ledger held them before the badge authority judged its first badge frame. B2's cutover
# takes them as earned before it (legacy); a bit gained after must be explained.
Sequel.migration do
  change do
    create_table(:badge_baselines) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Bignum   :mask,     null: false
      DateTime :taken_at, null: false

      primary_key %i[account_id]
    end
  end
end
