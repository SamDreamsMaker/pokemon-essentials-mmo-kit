# frozen_string_literal: true

# Badge authority B2 (docs/BADGE-AUTHORITY-DESIGN.md): why the server owns each badge bit
# of an account - legacy (held before the cutover), proof (a proven win), local (the
# client's word for a source the operator listed), operator - and when it cut over to
# owning them (one row: before it, an account's badges may be legacy).
Sequel.migration do
  change do
    create_table(:badge_grants) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Integer  :badge,       null: false
      String   :evidence,    size: 16, null: false
      String   :source,      size: 160               # the claim, the event, the operator's note
      Bignum   :claim_nonce
      DateTime :granted_at,  null: false

      primary_key %i[account_id badge]
    end

    create_table(:badge_cutover) do
      Integer  :id, primary_key: true                 # 1
      DateTime :at, null: false
    end
  end
end
