# frozen_string_literal: true

# Milestone 1 schema: accounts (auth), characters (opaque save blob + projected
# identity), sessions (opaque token, stored hashed). Economy ledger + monsters
# arrive in M2/M3.
Sequel.migration do
  change do
    run "CREATE EXTENSION IF NOT EXISTS citext"

    create_table(:accounts) do
      primary_key :id, type: :Bignum
      column      :username, :citext, null: false
      column      :email,    :citext
      String      :password_hash, null: false          # bcrypt(cost 12) of sha256(pw)
      String      :status, null: false, default: "active"
      Integer     :failed_count, null: false, default: 0
      DateTime    :locked_until
      DateTime    :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime    :last_login_at

      index :username, unique: true
      index :email, unique: true, where: Sequel.~(email: nil)   # unique only for real emails
    end

    create_table(:characters) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Integer     :trainer_id                            # stamped onto $player client-side
      column      :save_blob, :bytea                     # opaque — NEVER Marshal.load'd server-side
      Integer     :save_version
      Integer     :wire_version
      DateTime    :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :account_id, unique: true                    # M1: one character per account
    end

    create_table(:sessions) do
      column      :token_sha256, :bytea, null: false     # sha256 of the opaque token; token itself never stored
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      DateTime    :issued_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime    :last_seen_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime    :expires_at, null: false
      TrueClass   :revoked, null: false, default: false
      column      :remote_addr, :inet

      primary_key [:token_sha256]
      index :account_id
    end
  end
end
