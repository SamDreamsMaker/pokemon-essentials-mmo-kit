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
    # Fields whose value is PROGRESSION rather than currency: they only ever grow, so
    # the server unions instead of assigning and a rollback cannot erase them. Enabled
    # with the sovereignty layer (flag_state); a fork that deliberately revokes badges
    # in a story beat must keep that off, or clear the balance through an operator path.
    MONOTONIC = %i[badges].freeze
    SEQ_MAX   = 1 << 53   # a client frame's seq stays below this (and above zero)

    def initialize(db, caps, monotonic: false)
      @db   = db
      @caps = caps            # { money: 999_999, coins: ..., ... }
      @monotonic = monotonic
    end

    def monotonic?(key)
      @monotonic && MONOTONIC.include?(key)
    end

    # -> [:ack, balance] | [:dup, recorded_balance] | [:rej, current_balance, reason]
    # +reason+ (M4 D4) attributes the ledger row (default "unattributed"); a caller can
    # pass "battle:<n>" / "battle_suspect:<n>". Backward-compatible — old call sites omit it.
    # +no_increase+ (money authority M3): every increase is a transaction the server
    # makes itself, so a fresh value above the balance is refused - recorded under its seq
    # with the balance unchanged, the ledger showing the refusal and the client's next
    # frame never taken for a replay of it.
    # +hold+ (badge authority B2): the frame moves nothing - only the server's grants do; it
    # is recorded under its seq, the balance untouched. -> [:held, balance]
    def apply_econ(account_id, field, value, seq, now: Time.now, reason: "unattributed", no_increase: false, hold: false)
      key = field.to_s.to_sym
      cap = @caps[key]
      return [:rej, current(account_id, field), :bad_field] unless cap && value.is_a?(Integer) && seq.is_a?(Integer)
      # A client frame's seq is positive and bounded: the server's own rows take the
      # negative ones below the lowest (adjust), which a huge negative one would overflow.
      return [:rej, current(account_id, field), :bad_seq] unless seq.positive? && seq < SEQ_MAX

      result = nil
      @db.transaction do
        recorded = @db[:economy_ledger].where(account_id: account_id, field: field.to_s, seq: seq).get(:balance_after)
        if recorded
          result = [:dup, recorded]                       # already applied this seq -> re-ack the recorded value
        else
          cur = current(account_id, field)
          # Badges are progression, not currency: a player never loses one in normal
          # play, so the bitmask is unioned instead of assigned. A reloaded save that
          # predates a badge pushes 0 and would otherwise erase it - observed in a live
          # session right after a rollback. The union keeps what was earned and the ack
          # hands the repaired mask straight back to the client.
          # Unconditional: a bitmask union is the whole semantics. Gating it on
          # "value < cur" still loses a bit on a sideways change (0b0001 -> 0b0100),
          # which a test caught.
          value |= cur if monotonic?(key)
          if value.negative? || value > cap
            result = [:rej, cur, :cap]
          elsif hold
            @db[:economy_balances]
              .insert_conflict(target: %i[account_id field], update: { last_seq: seq })
              .insert(account_id: account_id, field: field.to_s, balance: cur, last_seq: seq)
            @db[:economy_ledger].insert(account_id: account_id, field: field.to_s, delta: 0,
                                        reason: "held", seq: seq, balance_after: cur, created_at: now)
            result = [:held, cur]
          elsif no_increase && value > cur
            @db[:economy_balances]
              .insert_conflict(target: %i[account_id field], update: { last_seq: seq })
              .insert(account_id: account_id, field: field.to_s, balance: cur, last_seq: seq)
            @db[:economy_ledger].insert(account_id: account_id, field: field.to_s, delta: 0,
                                        reason: "refused:+#{value - cur}", seq: seq, balance_after: cur, created_at: now)
            result = [:rej, cur, :unexplained]
          else
            @db[:economy_balances]
              .insert_conflict(target: %i[account_id field], update: { balance: value, last_seq: seq })
              .insert(account_id: account_id, field: field.to_s, balance: value, last_seq: seq)
            @db[:economy_ledger].insert(
              account_id: account_id, field: field.to_s, delta: value - cur,
              reason: reason.to_s, seq: seq, balance_after: value, created_at: now
            )
            result = [:ack, value]
          end
        end
      end
      result
    end

    # A change the server makes itself (a Mart purchase or sale): +delta+ on +field+,
    # within 0..cap. Its ledger row takes a negative seq, which no client frame uses, and
    # the balance's last_seq is left alone, so the client's next seq still follows its
    # own. -> [:ack, balance] | [:rej, balance, :funds | :cap | :bad_field]
    def adjust(account_id, field, delta, reason:, now: Time.now)
      key = field.to_s.to_sym
      cap = @caps[key]
      return [:rej, current(account_id, field), :bad_field] unless cap && delta.is_a?(Integer)

      result = nil
      @db.transaction do
        cur = current(account_id, field)
        value = cur + delta
        if value.negative?
          result = [:rej, cur, :funds]
        elsif value > cap
          result = [:rej, cur, :cap]
        else
          low = @db[:economy_ledger].where(account_id: account_id, field: field.to_s).min(:seq) || 0
          @db[:economy_balances]
            .insert_conflict(target: %i[account_id field], update: { balance: value })
            .insert(account_id: account_id, field: field.to_s, balance: value, last_seq: 0)
          @db[:economy_ledger].insert(account_id: account_id, field: field.to_s, delta: delta, reason: reason.to_s,
                                      seq: [low, 0].min - 1, balance_after: value, created_at: now)
          result = [:ack, value]
        end
      end
      result
    end

    def current(account_id, field)
      @db[:economy_balances].where(account_id: account_id, field: field.to_s).get(:balance) || 0
    end

    # Badge authority B2: the server sets badge bits itself - a proven win, the cutover, the
    # operator - bitwise, under the badges row's lock (an adjust's delta from a stale read
    # would carry: two grants of one bit, a badge nobody earned), with +grants+ (the
    # badge_grants rows) in the same transaction. -> the mask after
    def grant_bits(account_id, mask, reason:, grants: [], now: Time.now)
      set_badges(account_id, reason: reason, grants: grants, now: now) { |cur| cur | mask }
    end

    # The badges the ledger holds become exactly +mask+ (the boot pass: what the server
    # owns). -> the mask after
    def set_badge_bits(account_id, mask, reason:, grants: [], now: Time.now)
      set_badges(account_id, reason: reason, grants: grants, now: now) { |_cur| mask }
    end

    # Was this (account, field, seq) already applied? (D4: attribute/consume budget only
    # for a genuinely new frame, never a reconnect replay.)
    def recorded?(account_id, field, seq)
      return false unless Ledger.seq_ok?(seq)   # never applied - and never a query the database refuses

      !@db[:economy_ledger].where(account_id: account_id, field: field.to_s, seq: seq).empty?
    end

    # A client frame's seq: an Integer above zero and below SEQ_MAX.
    def self.seq_ok?(seq)
      seq.is_a?(Integer) && seq.positive? && seq < SEQ_MAX
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

    private

    # The badges row, locked: yields its mask, writes what the block returns (a server row
    # under a negative seq, like adjust; the client's last_seq untouched) and +grants+.
    def set_badges(account_id, reason:, now:, grants: [])
      @db.transaction do
        @db[:economy_balances].insert_conflict(target: %i[account_id field])
                              .insert(account_id: account_id, field: "badges", balance: 0, last_seq: 0)
        rows = @db[:economy_balances].where(account_id: account_id, field: "badges")
        cur = rows.for_update.get(:balance).to_i
        value = yield(cur)
        grants.each do |g|
          @db[:badge_grants].insert_conflict(target: %i[account_id badge])
                            .insert(g.merge(account_id: account_id, granted_at: g[:granted_at] || now))
        end
        if value != cur
          low = @db[:economy_ledger].where(account_id: account_id, field: "badges").min(:seq) || 0
          rows.update(balance: value)
          @db[:economy_ledger].insert(account_id: account_id, field: "badges", delta: value - cur, reason: reason.to_s,
                                      seq: [low, 0].min - 1, balance_after: value, created_at: now)
        end
        value
      end
    end
  end
end
