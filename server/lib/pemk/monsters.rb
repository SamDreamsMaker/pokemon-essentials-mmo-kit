# frozen_string_literal: true

require "time"
require "json"

module PEMK
  # Server-issued monster UIDs (M3.1) — the identity registry + party shadow.
  #
  # MINT: the client sweeps its party+boxes for Pokémon without a uid and batch-
  # requests one per instance, correlated by a PERSISTED random nonce. Idempotency
  # is structural, not protocol: UNIQUE(issuer_account_id, client_nonce) means any
  # replay (lost grant, reconnect, crash-after-save) re-finds the SAME uid — a
  # duplicate mint is impossible by construction. Seq high-water is deliberately
  # NOT used here: it answers "did I apply this frame", not "what uid did I
  # already give this instance".
  #
  # PROJECT: the client pushes its party as an absolute [{uid, species, level}]
  # snapshot (high-water seq, verbatim from Inventory#apply_inv). We cross-check
  # each uid against the registry and FLAG — never reject — foreign_uid (owned by
  # another account: the copied-save case), dup_in_party (in-save clone), and
  # unknown_uid (no registry row). nil uids are legal (mint in flight); species/
  # level drift vs at-issue values is NORMAL (evolution/level-up), never flagged.
  #
  # HONEST: this makes instances traceable and (in M3.2) trade-gated — NOT
  # unforgeable. A modified client can fabricate a plausible mon and get it a uid;
  # acquisition validation is M4+. Runs under the per-account PlayerMailbox.
  class Monsters
    def initialize(db, caps, logger: nil)
      @db   = db
      @caps = caps                 # { uid_req_max:, party_max:, level_max: }
      @log  = logger || ->(_m) {}
    end

    # -> [:ack, grants] | [:rej, ["bad_shape"]]   (grants = [{tmp:, uid:}, ...])
    def mint_batch(account_id, mons)
      return [:rej, ["bad_shape"]] unless mons.is_a?(Array) && mons.size <= @caps[:uid_req_max]

      grants = []
      @db.transaction do
        mons.each do |m|
          unless valid_mint_entry?(m)
            @log.call("mon: account #{account_id} bad mint entry #{m.inspect[0, 120]} -> skip")
            next
          end

          uid = mint_one(account_id, m)
          grants << { tmp: m[:tmp], uid: uid } if uid
        end
      end
      [:ack, grants]
    end

    # -> [:ack, flags] | [:dup, []] | [:rej, ["bad_shape"]]
    def apply_party(account_id, mons, seq, now: Time.now)
      return [:rej, ["bad_shape"]] unless well_formed_party?(mons) && seq.is_a?(Integer)

      result = nil
      @db.transaction do
        row = @db[:party_snapshots].where(account_id: account_id).first
        if row && seq <= row[:last_seq]
          result = [:dup, []]                      # replayed/stale absolute snapshot -> re-ack, no write
        else
          flags = check_party(account_id, mons, now)
          stored = mons.map { |m| m.each_with_object({}) { |(k, v), h| h[k.to_s] = v.is_a?(Symbol) ? v.to_s : v } }
          fields = {
            party: Sequel.pg_jsonb(stored), last_seq: seq,
            flagged: !flags.empty?, flags: Sequel.pg_jsonb(flags), updated_at: now
          }
          @db[:party_snapshots]
            .insert_conflict(target: :account_id, update: fields) # adopt EVEN WHEN flagged, or the record drifts
            .insert(fields.merge(account_id: account_id))
          result = [:ack, flags]
        end
      end
      result
    end

    # login_ok / auth_ok: the client's next-:mon-seq authority.
    def mon_seq(account_id)
      @db[:party_snapshots].where(account_id: account_id).get(:last_seq) || 0
    end

    # M3.2 login enforcement (detection->enforcement flip): the POSITIVE list of
    # uids this account TRADED AWAY and does NOT currently own — the client evicts
    # exactly these from a possibly-stale blob at load. A positive list (not a
    # set-difference from "owned") can never delete a legit mon on a missing/racing
    # row. Trade-backs self-exclude: if B trades a uid back to A, A's current
    # owner == A, so it drops out of A's list. Bounded by trade history.
    def evictions(account_id)
      @db[:monster_transfers]
        .join(:monsters, Sequel[:monsters][:id] => Sequel[:monster_transfers][:uid])
        .where(Sequel[:monster_transfers][:from_account_id] => account_id)
        .exclude(Sequel[:monsters][:owner_account_id] => account_id)
        .distinct
        .select_map(Sequel[:monster_transfers][:uid])
    end

    private

    def valid_mint_entry?(m)
      m.is_a?(Hash) &&
        m[:tmp].is_a?(Integer) && m[:tmp].positive? &&
        (m[:species].is_a?(Symbol) || m[:species].is_a?(String)) &&
        m[:level].is_a?(Integer) && m[:level].between?(1, @caps[:level_max]) &&
        m[:pid].is_a?(Integer) &&
        [true, false].include?(m[:egg])
    end

    # Lookup-or-mint against the monsters_mint_dedup unique index. insert_conflict
    # returns nil on conflict -> re-SELECT the existing row (same instance, replayed
    # request). The rescue is belt-and-braces for the race the mailbox already
    # prevents per-account.
    def mint_one(account_id, m)
      uid = @db[:monsters].insert_conflict.insert(
        owner_account_id:  account_id,
        issuer_account_id: account_id,
        client_nonce:      m[:tmp],
        species:           m[:species].to_s,
        level_at_issue:    m[:level],
        personal_id:       m[:pid],
        egg_at_issue:      m[:egg]
      )
      uid || existing_uid(account_id, m[:tmp])
    rescue Sequel::UniqueConstraintViolation
      existing_uid(account_id, m[:tmp])
    end

    def existing_uid(account_id, nonce)
      @db[:monsters].where(issuer_account_id: account_id, client_nonce: nonce).get(:id)
    end

    def well_formed_party?(mons)
      mons.is_a?(Array) && mons.size <= @caps[:party_max] &&
        mons.all? do |m|
          m.is_a?(Hash) &&
            (m[:uid].nil? || m[:uid].is_a?(Integer)) &&
            (m[:species].is_a?(Symbol) || m[:species].is_a?(String)) &&
            m[:level].is_a?(Integer)
        end
    end

    # Registry cross-check -> flag reasons. nil uids (mint in flight) tolerated.
    def check_party(account_id, mons, now)
      flags = []
      uids  = mons.map { |m| m[:uid] }.compact
      flags << "dup_in_party" if uids.size != uids.uniq.size

      return flags if uids.empty?

      rows = @db[:monsters].where(id: uids.uniq).select_hash(:id, :owner_account_id)
      uids.uniq.each do |uid|
        owner = rows[uid]
        if owner.nil?
          flags << "unknown_uid"
          @log.call("mon: account #{account_id} projected unknown uid #{uid}")
        elsif owner != account_id
          flags << "foreign_uid"
          sighting = { "seen_by" => account_id, "at" => now.utc.iso8601, "kind" => "foreign_uid" }
          @db[:monsters].where(id: uid).update(
            flagged: true,
            flags:   Sequel.lit("flags || ?::jsonb", [sighting].to_json),
            updated_at: now
          )
          @log.call("mon: account #{account_id} projected FOREIGN uid #{uid} (owner #{owner}) -> flagged")
        end
      end
      flags.uniq
    end
  end
end
