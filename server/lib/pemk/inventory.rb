# frozen_string_literal: true

module PEMK
  # Server-side BAG record, DETECTION-ONLY. The client pushes the WHOLE bag as an
  # absolute {item_id => qty} snapshot (reconnect-safe + self-healing, exactly like
  # Ledger#apply_econ takes the absolute post-clamp value). We RECORD it and
  # structurally FLAG anomalies, but NEVER reject/roll back: without a GameData::Item
  # registry and server-side gameplay (M3) we cannot validate item ACQUISITION. A
  # modified client can send a fully plausible within-cap bag of real-id items and
  # pass every check — same caveat as the economy ledger. The bag stays
  # blob-authoritative in M2.3; this row is a detection shadow + the trading
  # foundation.
  #
  # Idempotent by nature (an absolute snapshot) -> a simple last_seq high-water dedup,
  # NOT economy_ledger's gap-safe per-(account,field,seq) scheme (row-existence would
  # wrongly accept a replayed OLDER whole-bag). Runs under the per-account
  # PlayerMailbox, so an account's :inv/:econ/:save are already serialized.
  class Inventory
    DIVERGENCE_MIN = 8   # only log a blob-vs-record divergence this material (coarse tamper signal)

    def initialize(db, caps, logger: nil)
      @db   = db
      @caps = caps                 # { per_item:, distinct:, total: }
      @log  = logger || ->(_m) {}
    end

    # -> [:ack, flags] | [:dup, []] | [:rej, ["bad_shape"]]
    def apply_inv(account_id, bag, seq, now: Time.now)
      return [:rej, ["bad_shape"]] unless bag.is_a?(Hash) && seq.is_a?(Integer)

      result = nil
      @db.transaction do
        row = @db[:inventory_snapshots].where(account_id: account_id).first
        if row && seq <= row[:last_seq]
          result = [:dup, []]                       # replayed/stale absolute snapshot -> re-ack, no write
        else
          flags = validate(bag)
          log_divergence(account_id, row, bag) if row
          stored   = bag.each_with_object({}) { |(k, v), h| h[k.to_s] = v }  # jsonb keys are strings
          distinct = bag.size
          total    = bag.values.sum { |v| v.is_a?(Integer) ? v : 0 }
          fields = {
            bag: Sequel.pg_jsonb(stored), last_seq: seq,
            distinct_items: distinct, total_qty: total,
            flagged: !flags.empty?, flags: Sequel.pg_jsonb(flags), updated_at: now
          }
          @db[:inventory_snapshots]
            .insert_conflict(target: :account_id, update: fields)  # adopt EVEN WHEN flagged, or the record drifts
            .insert(fields.merge(account_id: account_id))
          result = [:ack, flags]
        end
      end
      result
    end

    # login_ok / auth_ok: the client adopts inv_seq as its next :inv-seq authority.
    # The full bag is deliberately NOT shipped — reconcile is server-side, so a
    # client-held server-bag would be wasted bytes a cheater controls anyway.
    def snapshot(account_id)
      { last_seq: @db[:inventory_snapshots].where(account_id: account_id).get(:last_seq) || 0 }
    end

    # Headless STRUCTURAL checks -> array of reason strings. FLAG, never reject.
    # (No GameData::Item on a headless server, so item-id existence is out of reach.)
    def validate(bag)
      flags = []
      flags << "bad_key"        unless bag.keys.all? { |k| k.is_a?(Symbol) }
      flags << "bad_qty"        unless bag.values.all? { |v| v.is_a?(Integer) && v >= 0 }
      flags << "over_item_cap"  if bag.values.any? { |v| v.is_a?(Integer) && v > @caps[:per_item] }
      flags << "too_many_items" if bag.size > @caps[:distinct]
      total = bag.values.sum { |v| v.is_a?(Integer) ? v : 0 }
      flags << "over_total"     if total > @caps[:total]
      flags
    end

    private

    # Coarse blob-vs-record divergence signal (a save-file edit that bypassed the
    # observers shows up as a large first-post-login diff). Small diffs are EXPECTED
    # in normal play (the opaque blob pushes throttled while :inv debounces), so only
    # material divergence is logged, and NEVER as a cheat verdict.
    def log_divergence(account_id, row, bag)
      prev = row[:bag] || {}
      cur  = bag.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      appeared    = (cur.keys - prev.keys).size
      disappeared = (prev.keys - cur.keys).size
      changed     = (cur.keys & prev.keys).count { |k| cur[k] != prev[k] }
      material    = appeared + disappeared + changed
      return if material < DIVERGENCE_MIN

      @log.call("inv: account #{account_id} bag divergence +#{appeared}/-#{disappeared}/~#{changed} (blob-vs-record signal)")
    rescue StandardError
      nil
    end
  end
end
