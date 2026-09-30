# frozen_string_literal: true

require "json"

module PEMK
  # Trainer proof P3 (docs/TRAINER-PROOF-DESIGN.md, review H2): a replay proves a battle
  # was won with the team the record says - which is the client's word. Each Pokemon of
  # that team must be one the server knows for this account: registered (a uid), owned,
  # not quarantined, its first-sight lock kept (IVs, shiny, gender - audit item 5) and no
  # more EXP than the server has seen (D6). With the game's battle data (P4's review): the
  # species it was first seen as or an evolution of it, and a legal set (D1's TeamAudit).
  # And the record is replayed on its seed row's seed, against that row's trainer - never
  # on what its body says. Database and data only: runs in the replay tool.
  module ProofChecks
    STATS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze
    IV_TRAINED = 31   # Hyper Training raises an IV to this, the one legal change
    # A move or an ability no data explains may have come from an event script: the set
    # is then unprovable, not refuted.
    LEGIT_ELSEWHERE = %w[illegal_move: illegal_ability:].freeze

    module_function

    # A trainer record bound to a seed row is that row's battle: run on the row's seed (the
    # one the ingest walked), against the row's trainer. -> [the record to replay, nil] |
    # [nil, why it is not its seed row's battle]
    def bind_to_seed(record, stored_seed, seed_row)
      return [nil, "the record is not a trainer battle's (#{record[:kind].inspect})"] unless record[:kind] == "trainer"
      return [nil, "the record says it ran on no seed (#{record[:mode].inspect})"] unless record[:mode].to_s == "on"
      unless record[:seed] == stored_seed && stored_seed == seed_row[:seed]
        return [nil, "the record names another seed than its battle's"]
      end

      want = [[seed_row[:tr_type], seed_row[:tr_name], seed_row[:tr_version]]]
      got = Array(record[:trainers]).map { |t| Array(t).map { |v| v.is_a?(Symbol) ? v.to_s : v } }
      return [nil, "the record names another trainer than its seed's (#{got.inspect})"] unless got == want

      [record.merge(seed: seed_row[:seed], mode: "on"), nil]
    end

    PARTY_MAX = 6
    MOVES_MAX = 4
    UID_MAX   = (1 << 63) - 1   # a registry id is a bigint

    # A team no game fields: more than six, one Pokemon twice, more than four moves.
    # -> why, or nil
    def team_shape(record)
      frames = player_frames(record)
      return "more than #{PARTY_MAX} Pokemon in the player's team" if frames.size > PARTY_MAX

      uids = frames.map { |f| f.is_a?(Hash) ? f[:uid] : nil }.compact
      return "one Pokemon twice in the player's team" if uids.uniq.size != uids.size
      return "a Pokemon with more than #{MOVES_MAX} moves" if frames.any? { |f| f.is_a?(Hash) && Array(f[:moves]).size > MOVES_MAX }

      nil
    end

    def player_frames(record)
      Array(record.is_a?(Hash) && record[:init].is_a?(Hash) ? record[:init][:player] : nil).compact
    end

    # -> [:ok | :unprovable | :refuted, reason | nil]. +audit+: a TeamAudit on the game's
    # battle data.
    def player_team(db, account_id, record, audit: nil)
      frames = player_frames(record)
      return [:unprovable, "no player team in the record"] if frames.empty?
      if (shape = team_shape(record))
        return [:refuted, shape]
      end

      # The badges set how high a traded Pokemon obeys: no more than the server knows.
      claimed = record[:init][:badges]
      if claimed.is_a?(Integer) && claimed > (known = server_badges(db, account_id))
        return [:refuted, "#{claimed} badges in the record, the server knows #{known}"]
      end

      unprovable = nil
      frames.each_with_index do |f, i|
        uid = f.is_a?(Hash) ? f[:uid] : nil
        unless uid.is_a?(Integer) && uid.between?(1, UID_MAX)
          unprovable ||= "player #{i}: a Pokemon the server has not registered yet"
          next
        end
        verdict, why = pokemon(db, account_id, uid, f, audit)
        return [:refuted, "player #{i} (uid #{uid}): #{why}"] if verdict == :refuted

        unprovable ||= "player #{i} (uid #{uid}): #{why}" if verdict == :unprovable
      end
      unprovable ? [:unprovable, unprovable] : [:ok, nil]
    end

    # -> [:refuted | :unprovable, why] when this frame is not the server's Pokemon +uid+
    # of +account_id+ as it may be, or nil.
    def pokemon(db, account_id, uid, frame, audit = nil)
      mon = db[:monsters].where(id: uid).first
      return [:refuted, "not this account's"] unless mon && mon[:owner_account_id] == account_id
      return [:refuted, "#{mon[:status]}, not active"] unless mon[:status] == "active"
      # Traded in from another account, the game saw it as another trainer's (it obeys only
      # so far): a record saying it is the player's own would spare it that. (An egg takes
      # the trainer who hatches it.)
      if frame[:foreign] == false && mon[:issuer_account_id] != account_id && !mon[:egg_at_issue]
        return [:refuted, "a Pokemon from another account, recorded as the player's own"]
      end

      lock = db[:monster_blocks].where(uid: uid).first
      if lock
        why = kept_lock(lock, frame)
        return [:refuted, why] if why
      end
      # The replay's level follows its EXP: a record without it would choose its level.
      exp = frame[:exp]
      return [:refuted, "no EXP in the record"] unless exp.is_a?(Integer)

      seen = db[:monster_stats].where(uid: uid).get(:exp)
      return [:refuted, "EXP #{exp}, more than the #{seen} the server has seen"] if seen && exp > seen

      set = audit ? legal_set(audit, (lock && lock[:species]) || mon[:species], frame) : nil
      return set if set

      seen ? nil : [:unprovable, "no EXP the server has seen for it"]
    end

    # The species a uid can be - the one it was first seen as (or issued as), or an
    # evolution of it - and a legal set.
    def legal_set(audit, first_species, frame)
      if first_species
        family = audit.evolves_from?(frame[:species], first_species)
        return [:refuted, "species #{frame[:species]} is not #{first_species} or an evolution of it"] if family == false
        return [:unprovable, "species #{frame[:species]}: the battle data cannot say"] if family.nil?
      end
      hard = audit.hard_violations(audit_frame(frame))
      return nil if hard.empty?

      firm = hard.reject { |v| LEGIT_ELSEWHERE.any? { |p| v.start_with?(p) } }
      return [:refuted, "an illegal set: #{firm.join(', ')}"] unless firm.empty?

      [:unprovable, "a set no data explains: #{hard.join(', ')}"]
    end

    # A record's mon frame as TeamAudit takes one - its six stats only, as the replay reads
    # them (a key of the client's own is no stat, and no text of a verdict).
    def audit_frame(f)
      stats = ->(h) { h.is_a?(Hash) ? STATS.to_h { |s| [s, h[s] || h[s.to_sym]] }.compact : nil }
      { "species" => f[:species].to_s, "level" => f[:level], "ivs" => stats.(f[:iv]), "evs" => stats.(f[:ev]),
        "moves" => Array(f[:moves]).map(&:to_s), "ability" => f[:ability], "nature" => f[:nature], "item" => f[:item] }
    end

    def kept_lock(lock, frame)
      locked = hash_of(lock[:ivs])
      ivs = frame[:iv].is_a?(Hash) ? frame[:iv] : {}
      STATS.each do |s|
        want = locked[s]
        got  = ivs[s] || ivs[s.to_sym]
        next if want.nil? || got == want || got == IV_TRAINED

        return "IV #{s} #{got.inspect}, locked at #{want}"
      end
      return "shiny changed" if (frame[:shiny] == true) != (lock[:shiny] == true)
      return "gender changed" if !lock[:gender].nil? && frame[:gender] != lock[:gender]

      nil
    end

    # The badges the server knows the account has: its ledger's mask.
    def server_badges(db, account_id)
      db[:economy_balances].where(account_id: account_id, field: "badges").get(:balance).to_i.to_s(2).count("1")
    end

    # A record's words, safe to store and print: its bytes may be anything a client sent
    # (the database refuses invalid UTF-8 and NUL). At most 1000 characters.
    def safe_text(value)
      return nil if value.nil?

      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").delete("\u0000")[0, 1000]
    end

    # A jsonb column as a Hash: JSON text without the pg_json extension (the replay tool's
    # plain connection), a delegate with it.
    def hash_of(value)
      return JSON.parse(value) if value.is_a?(String)

      value.respond_to?(:to_hash) ? value.to_hash : {}
    rescue JSON::ParserError
      {}
    end
  end
end
