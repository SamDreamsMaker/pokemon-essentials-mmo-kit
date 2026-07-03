# frozen_string_literal: true

module PEMK
  # Server-authoritative economy. The client sends the ABSOLUTE post-clamp value
  # for a field with a per-channel seq (the observer only ever sees the absolute,
  # so a reconnect-safe delta is impossible to compute client-side). We validate
  # against the game cap, dedup by ledger-row existence (gap-safe idempotency), and
  # keep a materialized balance. This is cap-enforcement + an audit trail — NOT
  # anti-cheat: a modified client can still inject a within-cap value (reason stays
  # :unattributed). All calls run inside a per-player mailbox, so a given account's
  # mutations are already serialized (no read-modify-write race).
  class Ledger
    def initialize(db, caps)
      @db   = db
      @caps = caps            # { money: 999_999, coins: ..., ... }
    end

    # -> [:ack, balance] | [:dup, recorded_balance] | [:rej, current_balance, reason]
    def apply_econ(account_id, field, value, seq, now: Time.now)
      key = field.to_s.to_sym
      cap = @caps[key]
      return [:rej, current(account_id, field), :bad_field] unless cap && value.is_a?(Integer) && seq.is_a?(Integer)

      result = nil
      @db.transaction do
        recorded = @db[:economy_ledger].where(account_id: account_id, field: field.to_s, seq: seq).get(:balance_after)
        if recorded
          result = [:dup, recorded]                       # already applied this seq -> re-ack the recorded value
        else
          cur = current(account_id, field)
          if value.negative? || value > cap
            result = [:rej, cur, :cap]
          else
            @db[:economy_balances]
              .insert_conflict(target: %i[account_id field], update: { balance: value, last_seq: seq })
              .insert(account_id: account_id, field: field.to_s, balance: value, last_seq: seq)
            @db[:economy_ledger].insert(
              account_id: account_id, field: field.to_s, delta: value - cur,
              reason: "unattributed", seq: seq, balance_after: value, created_at: now
            )
            result = [:ack, value]
          end
        end
      end
      result
    end

    def current(account_id, field)
      @db[:economy_balances].where(account_id: account_id, field: field.to_s).get(:balance) || 0
    end

    # Canonical economy for login_ok reconciliation: { balances: {field=>value},
    # last_seq: N } (N = max applied economy seq, the client's next-seq authority).
    def snapshot(account_id)
      balances = {}
      last_seq = 0
      @db[:economy_balances].where(account_id: account_id).select(:field, :balance, :last_seq).each do |row|
        balances[row[:field].to_sym] = row[:balance]
        last_seq = row[:last_seq] if row[:last_seq] > last_seq
      end
      { balances: balances, last_seq: last_seq }
    end
  end
end
