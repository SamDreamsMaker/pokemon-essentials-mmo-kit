# frozen_string_literal: true

module PEMK
  # Server-authoritative trading — the atomic ownership swap (M3.2). This is the
  # single security invariant of the whole feature: a trade moves owner_account_id
  # for every uid in ONE @db.transaction or none of them move. Everything else
  # (handshake, escrow, UI) is UX layered on top and cannot violate this.
  #
  # Threats defeated here, regardless of what a fully-modified client does:
  #  - DUPE: all uids are FOR UPDATE-locked in ascending id order (a deadlock-free
  #    total order), each CAS requires owner==seller, and the summed rowcount must
  #    equal the expected count or the WHOLE trade rolls back. Two concurrent trades
  #    over a shared uid serialize on the lock; the loser re-evaluates its CAS
  #    against the new owner, matches 0 rows, and aborts.
  #  - THEFT: the CAS `owner_account_id == seller` clause matches 0 rows for any uid
  #    the seller does not currently own -> abort.
  #  - FLAGGED/CLONED laundering: `flagged == false` in the CAS gates them out.
  #  - REPLAY: the pre-swap trade_id check + UNIQUE(trade_id, uid) make a re-sent
  #    swap an idempotent no-op.
  # NOT secured here (M4): the traded Pokémon OBJECT's stat/acquisition legality.
  class Trades
    def initialize(db)
      @db = db
    end

    # -> [:ok, {a_recv:, b_recv:}] | [:ok_replay, {a_recv:, b_recv:}] | [:abort, reason]
    def execute_trade(trade_id, a:, b:, a_gives:, b_gives:, now: Time.now)
      result = nil
      @db.transaction do
        if @db[:monster_transfers].where(trade_id: trade_id).count.positive?
          result = [:ok_replay, replay_view(trade_id, a, b)]     # idempotent re-ack; NO re-swap
          next
        end

        all_uids = (a_gives + b_gives).uniq.sort
        @db[:monsters].where(id: all_uids).order(:id).for_update.select(:id).all  # LOCK ascending -> deadlock-free

        moved = 0
        rows  = []
        a_gives.each { |u| moved += cas(u, a, b, now); rows << xfer(trade_id, u, a, b, now) }
        b_gives.each { |u| moved += cas(u, b, a, now); rows << xfer(trade_id, u, b, a, now) }

        if moved != (a_gives.size + b_gives.size)
          result = [:abort, :ownership]
          raise Sequel::Rollback                                  # WHOLE trade rolls back — nothing moved
        end

        @db[:monster_transfers].multi_insert(rows)                # UNIQUE(trade_id, uid) dedup
        result = [:ok, { a_recv: b_gives, b_recv: a_gives }]
      end
      result
    end

    private

    # The theft gate AND the singularity gate. -> rowcount 0 | 1.
    def cas(uid, seller, buyer, now)
      @db[:monsters]
        .where(id: uid, owner_account_id: seller, status: "active", flagged: false)
        .update(owner_account_id: buyer, updated_at: now)
    end

    def xfer(trade_id, uid, from, to, now)
      { uid: uid, from_account_id: from, to_account_id: to, trade_id: trade_id, created_at: now }
    end

    def replay_view(trade_id, a, b)
      rows = @db[:monster_transfers].where(trade_id: trade_id).all
      { a_recv: rows.select { |r| r[:to_account_id] == a }.map { |r| r[:uid] },
        b_recv: rows.select { |r| r[:to_account_id] == b }.map { |r| r[:uid] } }
    end
  end
end
