# frozen_string_literal: true

# Trainer proof P4 (docs/TRAINER-PROOF-DESIGN.md): enforcement.
#
# money_daily.unproven_paid: the prizes paid today without a proof, which
# PEMK_MONEY_UNPROVEN_DAILY bounds.
# battle_records.client_nonce: a trainer battle's record is sent until the server
# acknowledges it - the same record sent again is a copy.
Sequel.migration do
  change do
    alter_table(:money_daily) do
      add_column :unproven_paid, :Bignum, null: false, default: 0
    end

    alter_table(:battle_records) do
      add_column :client_nonce, :Bignum, null: true
      add_index %i[account_id client_nonce], unique: true, where: Sequel.lit("client_nonce IS NOT NULL"),
                                             name: :battle_records_one_per_client_nonce
    end
  end
end
