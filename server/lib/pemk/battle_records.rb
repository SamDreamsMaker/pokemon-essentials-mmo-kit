# frozen_string_literal: true

module PEMK
  # M4 Layer D D7 part 1: the battle-record CORPUS ingest. The client's
  # :battle_record frame carries triage metadata in the primitive envelope and
  # the full record as an opaque primitive-encoded BODY — stored VERBATIM
  # (bytea) for part 2's headless replay; nothing here ever decodes the body
  # beyond a size gate, and nothing here rejects a battle (instrumentation).
  #
  # Seed binding: a record claiming a battle_seed must match a roll the server
  # minted FOR THIS ACCOUNT; the partial unique index on encounter_roll_id makes
  # the seed single-use (a second record for the same roll is dropped as a dup).
  # A record with no/unknown seed still ingests (shadow's broad corpus) — just
  # unbound. Runs under the per-account mailbox.
  class BattleRecords
    BODY_MAX   = 256 * 1024   # raw record cap (well above a truncated max record)
    MODES      = %w[shadow on].freeze
    HEX16      = /\A\h{16}\z/.freeze
    DRAWS_MAX  = 1_000_000    # sanity for the promoted counters
    HOURLY_CAP = 120          # records per account per hour (spam/storage bound —
                              # nobody finishes more wild battles than this honestly)
    # D7 part 3 — corpus retention: MATCHED records are spent (they proved parity)
    # and prune after this many days; every other status is EVIDENCE (mismatch /
    # walk_mismatch / no_log / mode_mismatch / error) or still-pending work and is
    # KEPT. Operators override via PEMK_CORPUS_RETENTION_DAYS (0 = keep forever).
    RETENTION_DAYS = 30
    CLIENT_NONCE   = (1...(1 << 62)).freeze   # a trainer battle record's nonce (P4)

    def initialize(db, mode: :off, logger: nil, trainer_battles: nil)
      @db   = db
      @mode = mode   # the SERVER's configured rng mode (masquerade detection)
      @log  = logger || ->(_m) {}
      @trainer_battles = trainer_battles   # trainer proof P2: the seeds of trainer battles
    end

    # Boot-time retention: drop MATCHED records older than +days+ (0 disables).
    # Non-match statuses are never pruned here — they are the operator's evidence.
    # -> rows deleted.
    def prune(days: RETENTION_DAYS, now: Time.now)
      return 0 unless days.positive?

      @db[:battle_records]
        .where(replay_status: "match")
        .where { created_at < now - (days * 86_400) }
        .delete
    end

    # -> :ok | :desync | :dup | :bad | :later | :error — telemetry; a record naming a client
    # nonce (a trainer battle's, P4) is acknowledged unless :later or :error (:desync =
    # ingested, but the seed walk refuted the claimed draws; :later = over the hourly cap;
    # :error = not stored: both sent again later).
    def ingest(account_id, env, body, now: Time.now)
      return :bad unless body.is_a?(String) && !body.empty? && body.bytesize <= BODY_MAX

      mode = env[:mode].to_s
      return :bad unless MODES.include?(mode)

      # Trainer proof P4: the client sends a trainer battle's record until it is acknowledged
      client_nonce = env[:rec_nonce].is_a?(Integer) && CLIENT_NONCE.cover?(env[:rec_nonce]) ? env[:rec_nonce] : nil
      if client_nonce && !@db[:battle_records].where(account_id: account_id, client_nonce: client_nonce).empty?
        return :dup
      end

      roll_id = nil
      trainer_battle_id = nil
      seed = env[:battle_seed]
      if seed.is_a?(Integer) && seed.positive?
        roll_id = @db[:encounter_rolls].where(account_id: account_id, battle_seed: seed).get(:id)
        # ... or a trainer battle's (P2): each attempt at a placement names its seed - an
        # open one (a spent seed's win is already proven; migration 044 keeps one win each).
        unless roll_id
          row = @trainer_battles&.row_for_seed(account_id, seed)
          trainer_battle_id = row[:id] if row && row[:state] == "open"
        end
        # an unknown seed is recorded UNBOUND, and loudly — either a stale relogin
        # or a fabricated claim; part 3's parity stats treat unbound `on` records
        # as first-class suspects.
        unless roll_id || trainer_battle_id
          @log.call("battlerec: account #{account_id} claimed unknown seed #{seed} (recording unbound)")
        end
      end

      # THE SEED WALK — the part-1 security check. An `on` record bound to a roll
      # claims its draws came from the seed's PCG32 streams: re-walk each stream over
      # the packed (bound, value) log and compare value-by-value, cross-checking the
      # promoted env counters/fps against the body. A mismatch means the client did
      # NOT draw from the seed (fabricated rolls, or an engine fork drawing
      # differently) — recorded, logged, D5-flagged, never rejected. Walk results
      # persist as DISTINCT statuses so an evasion (omitting logs) is as visible as
      # a failure (review-caught: :ok and :skipped both landing on "pending" made
      # log-stripping silent).
      # storage bound: an account can't grow the corpus faster than honest play - a
      # trainer battle's records apart, so no run of wild battles holds one back (P4)
      if over_cap?(account_id, !trainer_battle_id.nil?, now)
        @log.call("battlerec: account #{account_id} over the hourly record cap -> dropped")
        return client_nonce ? :later : :bad
      end

      walk = :unbound
      if roll_id || trainer_battle_id
        if mode == "on"
          walk = verify_walk(account_id, seed, env, body)
          # A trainer battle always draws: one that claims none dodged the walk (P4).
          if walk == :empty && trainer_battle_id
            walk = :no_log
            @log.call("battlerec: account #{account_id} trainer record on seed row #{trainer_battle_id} claims no draws (no_log)")
          end
        elsif @mode == :on
          # A roll-bound record claiming "shadow" under an `on` server: a modified
          # client dodging the walk — or an honest session from before an operator
          # flipped shadow->on (mode adopts at login). Distinct status, loud log,
          # NO flag (the honest case exists).
          walk = :mode_mismatch
          @log.call("battlerec: account #{account_id} bound record claims shadow under an on server (mode_mismatch)")
        end
      end

      @db[:battle_records].insert(
        account_id:        account_id,
        encounter_roll_id: roll_id,
        trainer_battle_id: trainer_battle_id,
        client_nonce:      client_nonce,
        mode:              mode,
        battle_seed:       (seed.is_a?(Integer) && seed.positive? ? seed : nil),
        engine_fp:         str_or_nil(env[:engine_fp], 64),
        record:            Sequel.blob(body),
        outcome:           int_in(env[:outcome], 0..5),
        rounds:            int_in(env[:rounds], 0..100_000),
        draws_battle:      int_in(env[:draws_battle], 0..DRAWS_MAX),
        draws_ai:          int_in(env[:draws_ai], 0..DRAWS_MAX),
        draws_run:         int_in(env[:draws_run], 0..DRAWS_MAX),
        fp_battle:         fp_or_nil(env[:fp_battle]),
        fp_ai:             fp_or_nil(env[:fp_ai]),
        fp_run:            fp_or_nil(env[:fp_run]),
        replay_status:     WALK_STATUS.fetch(walk, "pending"),
        created_at:        now
      )
      walk == :mismatch ? :desync : :ok
    rescue Sequel::UniqueConstraintViolation
      what = roll_id ? "roll #{roll_id}" : "the won battle on trainer seed #{trainer_battle_id}"
      @log.call("battlerec: account #{account_id} duplicate record for #{what} -> dropped")
      :dup
    rescue StandardError => e
      @log.call("battlerec: ingest failed #{e.class}: #{e.message}")
      :error
    end

    private

    TRAINER_HOURLY_CAP = 60   # trainer battles' records per account per hour (their own count)

    def over_cap?(account_id, trainer_bound, now)
      recent = @db[:battle_records].where(account_id: account_id).where { created_at > now - 3600 }
      if trainer_bound
        recent.exclude(trainer_battle_id: nil).count >= TRAINER_HOURLY_CAP
      else
        recent.where(trainer_battle_id: nil).count >= HOURLY_CAP
      end
    end

    # Streams to walk: record-hash key -> [PRNG stream id, env counter key].
    WALK_STREAMS = { b: [Prng::STREAM_BATTLE, :draws_battle],
                     a: [Prng::STREAM_AI,     :draws_ai],
                     r: [Prng::STREAM_RUN,    :draws_run] }.freeze

    WALK_STATUS = { unbound: "pending", ok: "walk_ok", empty: "walk_skipped",
                    no_log: "no_log", mismatch: "walk_mismatch",
                    mode_mismatch: "mode_mismatch" }.freeze

    MAX_LOGGED = 4096   # the client's per-stream packed-log cap (mirror)

    # -> :ok | :mismatch | :empty | :no_log
    #   :empty  = the record claims zero draws everywhere (trivial battle) — fine.
    #   :no_log = counters claim draws but the logs are absent/undecodable — walk
    #             EVADED; distinct status so part 3 ranks these next to mismatches.
    # Cross-checks (a lie about the record is a mismatch): env counter == body
    # stream :n; log pair-count == min(n, cap) unless truncated; recomputed FNV of
    # the walked pairs == the body fp when the log is complete.
    def verify_walk(account_id, seed, env, body)
      rec = Wire.decode_primitive(body)
      draws = rec.is_a?(Hash) && rec[:draws].is_a?(Hash) ? rec[:draws] : nil
      claimed_total = WALK_STREAMS.values.sum { |_, ck| env[ck].to_i }
      return (claimed_total.zero? ? :empty : :no_log) unless draws

      truncated = rec[:truncated] == true
      any_log = false
      WALK_STREAMS.each do |key, (stream_id, env_key)|
        s = draws[key]
        next unless s.is_a?(Hash)

        n   = s[:n].to_i
        log = s[:log].is_a?(String) ? s[:log] : "".b
        return fail_walk(account_id, key, "env counter #{env[env_key].inspect} != body n #{n}") if env[env_key].to_i != n
        next if n.zero? && log.empty?

        return fail_walk(account_id, key, "log absent for #{n} claimed draws") if log.empty?
        return fail_walk(account_id, key, "ragged log") unless (log.bytesize % 8).zero?

        pairs = log.unpack("N*")
        count = pairs.length / 2
        return fail_walk(account_id, key, "log has #{count} pairs, expected #{[n, MAX_LOGGED].min}") \
          if !truncated && count != [n, MAX_LOGGED].min

        any_log = true
        prng = Prng.new(seed, stream_id)
        fp   = FNV_OFFSET
        count.times do |i|
          bound, claimed = pairs[2 * i], pairs[2 * i + 1]
          derived = prng.rand_below(bound)
          return fail_walk(account_id, key, "draw #{i} bound #{bound}: claimed #{claimed}, seed derives #{derived}") \
            unless derived == claimed

          fp = fold32(fold32(fp, bound), claimed)
        end
        # a complete log's fingerprint is recomputable — a divergent one is a lie
        if !truncated && count == n && s[:fp].is_a?(String) && s[:fp] != format("%016x", fp)
          return fail_walk(account_id, key, "fp #{s[:fp]} != recomputed #{format('%016x', fp)}")
        end
      end
      return :empty if claimed_total.zero? && !any_log   # trivial 0-draw battle

      any_log ? :ok : :no_log
    end

    def fail_walk(account_id, stream, detail)
      @log.call("battlerec: account #{account_id} SUSPECT rng desync stream #{stream} — #{detail}")
      :mismatch
    end

    FNV_OFFSET = 0xcbf29ce484222325
    FNV_PRIME  = 0x100000001b3
    M64        = (1 << 64) - 1

    def fold32(h, v32)
      [v32].pack("N").each_byte { |b| h = ((h ^ b) * FNV_PRIME) & M64 }
      h
    end

    def str_or_nil(v, max)
      s = v.to_s
      s.empty? || s.length > max ? nil : s
    end

    def int_in(v, range)
      v.is_a?(Integer) && range.cover?(v) ? v : nil
    end

    def fp_or_nil(v)
      s = v.to_s
      HEX16.match?(s) ? s : nil
    end
  end
end
