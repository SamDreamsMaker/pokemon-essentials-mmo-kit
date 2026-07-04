# frozen_string_literal: true

module PEMK
  # One-shot overworld-pickup ledger (Milestone 4 Layer C). Records each account's
  # VALIDATED item-ball pickups keyed by tile; a repeat is a duplicate (a self-switch
  # reset / save-edit re-pickup = item dupe). Append-only, dedup via the
  # UNIQUE(account_id, map, x, y) index. Detection-only: record() reports :new vs
  # :dup, and never rejects. Runs under the per-account PlayerMailbox (never inline
  # on the reactor thread — it does a DB write).
  #
  # KNOWN LIMIT: keyed per account for all time, so deleting the save and starting a
  # NEW game on the same account would read old pickups as duplicates. Benign under
  # detection-only; a real reset hook is needed before this gates anything.
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
  end
end
