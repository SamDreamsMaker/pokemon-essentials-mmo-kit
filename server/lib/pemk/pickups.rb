# frozen_string_literal: true

module PEMK
  # One-shot overworld-pickup ledger (Milestone 4 Layer C). Records each account's
  # VALIDATED item-ball pickups keyed by tile; a repeat is a duplicate (a self-switch
  # reset / save-edit re-pickup = item dupe). Append-only, dedup via the
  # UNIQUE(account_id, map, x, y) index. record() reports :new vs :dup and never
  # rejects — the GRANT decision lives in the server (handle_pickup_req). Runs under
  # the per-account PlayerMailbox (never inline on the reactor thread — it does a DB
  # write).
  #
  # PICKUPS ARE PERMANENT PER ACCOUNT, by design — like the money ledger, badges, and
  # monster UIDs. A client "new game" on the SAME account does NOT re-enable already
  # taken item balls (your money doesn't refund either). A genuinely fresh start is a
  # NEW account, whose pickup rows are empty (the FK cascade on account delete wipes
  # them), so PEMK_PICKUP_ENFORCE is safe to default on: real players never hit a
  # stale-dup wall. The ONLY case needing a wipe is dev/QA re-testing a tile, exposed
  # via clear() behind the dev-only PEMK_ALLOW_PICKUP_RESET gate (see server.rb) —
  # never a client-obeyed reset (that would be an infinite item re-farm).
  class Pickups
    def initialize(db)
      @db = db
    end

    # -> :new (first time this account took this tile) | :dup (already recorded).
    def record(account_id, map, x, y, now: Time.now)
      @db[:pickups].insert(account_id: account_id, map: map, x: x, y: y, created_at: now)
      :new
    rescue Sequel::UniqueConstraintViolation
      :dup
    end

    # Whether this account already took the item at +map,x,y+ (for a future gate).
    def taken?(account_id, map, x, y)
      !@db[:pickups].where(account_id: account_id, map: map, x: x, y: y).empty?
    end

    # Dev/QA-only: forget every pickup this account has taken so its item balls can be
    # re-tested. Gated far upstream by PEMK_ALLOW_PICKUP_RESET (off in production) —
    # this method itself has no guard, so NEVER call it from a client-reachable path
    # without that gate. -> Integer rows deleted.
    def clear(account_id)
      @db[:pickups].where(account_id: account_id).delete
    end
  end
end
