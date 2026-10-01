# frozen_string_literal: true

module PEMK
  # M4 Layer D D5: statistical anomaly detection — the cross-battle BACKSTOP for the
  # residuals D2-D4 admit (HP-shaded catches, under-the-bound EXP, fabricated wild mons).
  # Purely server-side: it aggregates telemetry the earlier layers already produce into a
  # per-account risk picture and writes a human REVIEW QUEUE. It NEVER auto-enforces — a
  # lucky player looks like a cheat, so every signal is advisory.
  #
  # Two signals in this first cut:
  #   1. player_flags — discrete SUSPECT events (record_flag, atomic upsert) accumulated
  #      per account; a kind crossing its threshold is reported.
  #   2. provenance mix — a "client"-origin mon whose species EXISTS in a wild encounter
  #      table is a fabricated wild catch (D3.2 labels the honest one "wild_caught"); at
  #      volume, and outnumbering the account's real wild_caught, it is reported.
  #
  # THREADING: record_flag and sweep both use the Sequel connection pool (thread-safe)
  # and are called only from worker threads (never the reactor thread) — record_flag is
  # an atomic INSERT..ON CONFLICT, sweep is read-mostly + idempotent upserts, so no locks.
  class AnomalyDetector
    # A kind's count at/over its threshold opens a review report. Tuned generously
    # (detection, not punishment) — these are per-discrete-event, not per-resend.
    FLAG_THRESHOLDS = {
      "reward_money"        => 8,    # money deltas beyond a battle's yield
      "reward_level"        => 4,    # impossible party level jumps
      "catch_spam"          => 3,    # 21+ throws brute-forcing one mint
      "encounter_species"   => 5,    # locally-rolled a species not in the map table
      "encounter_wrong_map" => 8,    # claimed an encounter on a map they're not on
      "exp_rollback"        => 3,    # a mon's EXP dropped below its high-water (D6); latched
                                     # to 1 flag per episode, so 3 = 3 distinct rollback events
                                     # (a lone no-fault crash-restore is 1 and won't surface)
      "mon_counterfeit"     => 2,    # a mon's locked traits (IVs/shiny/gender) changed
      "gift_refarm"         => 2,    # the same one-shot event granting the same item again
      "gift_remote"         => 2,    # a gift asked from another map than its event's, by a
                                     # client that sends its position first
      "peer_body"           => 1,    # a body for another player naming a class no party holds:
                                     # an honest client never sends one
      "flag_rewind"         => 2,    # self-switches cleared en masse = a save rollback that
                                     # re-arms every one-shot event (NPC gifts, TMs, key items)
      "rng_desync"          => 3,    # an `on` battle record's draws refuted by the seed walk
                                     # (D7) — fabricated rolls, or a fork drawing differently;
                                     # 3 tolerates version-drift accidents before surfacing
      "item_unexplained"    => 3,    # item increases no server-known source explained (E2);
                                     # one per account and sweep, so 3 tolerates a source the
                                     # server does not model yet
      "item_correction_ignored" => 1, # a correction sent half an hour ago and still not applied
                                      # (E4): an honest client applies it on its next free frame
      "money_suspect"       => 2,    # a prize claimed over the bound its trainers and facts
                                     # allow (money authority M1)
      "money_claim"         => 3,    # prizes claimed away from their trainers, for trainers the
                                     # exports do not place, or rematches out of order or cadence
      "money_unexplained"   => 3,    # money a frame shows that no claim or deal explains (M1b)
      "badge_unexplained"   => 1,    # a badge no win explains, when the server could own them all
                                     # (badge authority B1): an honest client's badge comes after
                                     # its win's claim and record; once per frame, not per badge
      "badge_unprovable"    => 2     # a badge whose win no replay can prove (claimed with no seed,
                                     # a record the harness cannot replay): an honest client waits
                                     # for its seed, so 2 tolerates one battle begun offline
    }.freeze

    FABRICATED_WILD_MIN = 5   # >= this many client-origin wild-table mons to report

    # D7 part 3 — evasion-by-silence: caught seeded encounters whose battle record
    # never arrived. Only accounts that have EVER sent a record are judged (an old
    # client without the recorder plugin sends none — a mixed fleet must not flag);
    # a grace period covers in-flight/disconnect losses.
    SILENT_SEEDED_MIN = 5
    SILENT_GRACE_SEC  = 3600

    # D8 — claim-evasion: quarantine is keyed on the roll->mon link (claimed_monster_uid),
    # so a cheat could withhold the uid mint to keep a walk-CONDEMNED catch off the hook.
    # A condemned, caught roll that never minted its uid past the grace window is exactly
    # that dodge (an honest catch always self-heals a uid at flush). Report it.
    CLAIM_EVASION_MIN   = 3
    CLAIM_EVASION_GRACE = 3600

    def initialize(db, world, logger: nil)
      @db    = db
      @world = world
      @log   = logger || ->(_m) {}
    end

    # Atomically bump an account's counter for a discrete SUSPECT event. Fire-and-forget.
    def record_flag(account_id, kind, now: Time.now)
      k = kind.to_s
      @db[:player_flags]
        .insert_conflict(target: %i[account_id kind],
                         update: { count: Sequel[:player_flags][:count] + 1, last_at: now })
        .insert(account_id: account_id, kind: k, count: 1, first_at: now, last_at: now)
    rescue StandardError => e
      @log.call("anomaly: record_flag(#{kind}) failed #{e.class}: #{e.message}")
    end

    # The periodic aggregation: recompute both signals and refresh the review queue.
    # -> number of reports written/updated. Runs on a worker thread.
    def sweep(now: Time.now)
      n = sweep_flags(now) + sweep_provenance(now) + sweep_rng_silence(now) + sweep_claim_evasion(now)
      @log.call("anomaly: sweep refreshed #{n} report(s)") if n.positive?
      n
    rescue StandardError => e
      @log.call("anomaly: sweep failed #{e.class}: #{e.message}")
      0
    end

    # Open (unreviewed) reports, newest first — for an operator / admin surface.
    def open_reports(limit: 100)
      @db[:anomaly_reports].where(reviewed_at: nil).order(Sequel.desc(:updated_at)).limit(limit).all
    end

    private

    def sweep_flags(now)
      count = 0
      @db[:player_flags].each do |row|
        thr = FLAG_THRESHOLDS[row[:kind]]
        next unless thr && row[:count] >= thr

        upsert_report(row[:account_id], "flags:#{row[:kind]}", row[:count],
                      "#{row[:count]} #{row[:kind]} events (>= #{thr})", now)
        count += 1
      end
      count
    end

    def sweep_provenance(now)
      wild = @world.wild_species
      return 0 if wild.empty?

      # Let Postgres do the counting, grouped by the MINTER (issuer_account_id) — origin is
      # immutable across a trade while owner_account_id moves, so grouping by owner would
      # frame an innocent recipient of a fabricated mon (and let an attacker grief a victim's
      # queue). Eggs are excluded (gift/hatched eggs of wild species are legitimately
      # client-minted). origin is NULL for legacy / non-on-mode mints -> neither bucket.
      client_wild = counts_by_issuer(@db[:monsters].where(origin: "client", egg_at_issue: false, species: wild))
      wild_caught = counts_by_issuer(@db[:monsters].where(origin: "wild_caught"))

      count = 0
      client_wild.each do |account_id, cw|
        next unless cw >= FABRICATED_WILD_MIN && cw > wild_caught.fetch(account_id, 0)

        upsert_report(account_id, "fabricated_wild", cw,
                      "#{cw} client-origin wild-table mons vs #{wild_caught.fetch(account_id, 0)} wild_caught", now)
        count += 1
      end
      count
    end

    def counts_by_issuer(ds)
      out = {}
      ds.group_and_count(:issuer_account_id).each { |r| out[r[:issuer_account_id]] = r[:count] }
      out
    end

    # D7 part 3: a CAUGHT seeded encounter proves the battle concluded; a missing
    # battle record then means the client withheld it (walk/replay evasion by
    # silence). Judged only for record-capable accounts, past the grace window.
    def sweep_rng_silence(now)
      return 0 unless @db.table_exists?(:battle_records)

      capable = @db[:battle_records].distinct.select(:account_id)
      silent = @db[:encounter_rolls]
               .exclude(battle_seed: nil)
               .exclude(caught_at: nil)
               .where(account_id: capable)
               .where { created_at < now - SILENT_GRACE_SEC }
               .exclude(id: @db[:battle_records].exclude(encounter_roll_id: nil).select(:encounter_roll_id))

      count = 0
      silent.group_and_count(:account_id).each do |r|
        next unless r[:count] >= SILENT_SEEDED_MIN

        upsert_report(r[:account_id], "rng_silent", r[:count],
                      "#{r[:count]} caught seeded encounters with no battle record", now)
        count += 1
      end
      count
    end

    # D8: walk-CONDEMNED caught rolls that never minted their uid (dodging the
    # uid-keyed quarantine) past the grace window.
    def sweep_claim_evasion(now)
      return 0 unless @db.table_exists?(:encounter_rolls) && @db[:encounter_rolls].columns.include?(:condemned_at)

      evaded = @db[:encounter_rolls]
               .exclude(condemned_at: nil).exclude(caught_at: nil)
               .where(claimed_monster_uid: nil)
               .where { condemned_at < now - CLAIM_EVASION_GRACE }

      count = 0
      evaded.group_and_count(:account_id).each do |r|
        next unless r[:count] >= CLAIM_EVASION_MIN

        upsert_report(r[:account_id], "resim_claim_evasion", r[:count],
                      "#{r[:count]} walk-condemned caught encounters never minted a uid", now)
        count += 1
      end
      count
    end

    # Idempotent: refresh score/detail/updated_at, keep created_at and an operator's
    # reviewed_at (a reviewed account isn't re-alerted for the same kind).
    def upsert_report(account_id, kind, score, detail, now)
      @db[:anomaly_reports]
        .insert_conflict(target: %i[account_id kind],
                         update: { score: score, detail: detail, updated_at: now })
        .insert(account_id: account_id, kind: kind, score: score, detail: detail,
                created_at: now, updated_at: now)
    end
  end
end
