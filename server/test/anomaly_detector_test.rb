require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer D D5 anomaly detector: per-account SUSPECT counters (record_flag) + the
# periodic sweep that turns accumulated flags and a provenance mix into review-queue
# reports. DB-backed; never enforces.
class AnomalyDetectorTest < Minitest::Test
  class FakeWorld
    def wild_species; %w[PIDGEY RATTATA]; end
  end

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:anomaly_reports].delete rescue nil
    @db[:player_flags].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "an-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "an-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @det = PEMK::AnomalyDetector.new(@db, FakeWorld.new, logger: ->(m) { @logs << m })
    @nonce = 0
  end

  def teardown
    @db&.disconnect
  end

  def mon(owner, species, origin, issuer: owner, egg: false)
    @nonce += 1
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: issuer, client_nonce: @nonce,
                          species: species, level_at_issue: 5, personal_id: 1000 + @nonce,
                          egg_at_issue: egg, origin: origin)
  end

  def flag_count(account, kind)
    @db[:player_flags].where(account_id: account, kind: kind).get(:count)
  end

  def report(account, kind)
    @db[:anomaly_reports].where(account_id: account, kind: kind).first
  end

  # --- record_flag: atomic per-(account,kind) increment ------------------------------
  def test_record_flag_increments
    @det.record_flag(@a, :catch_spam)
    assert_equal 1, flag_count(@a, "catch_spam")
    @det.record_flag(@a, :catch_spam)
    @det.record_flag(@a, :catch_spam)
    assert_equal 3, flag_count(@a, "catch_spam")
    @det.record_flag(@a, :reward_money)                 # a different kind is its own row
    assert_equal 1, flag_count(@a, "reward_money")
    assert_equal 3, flag_count(@a, "catch_spam")
    @det.record_flag(@b, :catch_spam)                   # another account is independent
    assert_equal 1, flag_count(@b, "catch_spam")
  end

  # --- sweep: flag thresholds --------------------------------------------------------
  def test_sweep_reports_flags_at_or_over_threshold
    3.times { @det.record_flag(@a, :catch_spam) }       # threshold 3 -> reported
    2.times { @det.record_flag(@a, :reward_level) }     # threshold 4 -> NOT yet
    assert_equal 1, @det.sweep                          # only catch_spam crosses

    r = report(@a, "flags:catch_spam")
    refute_nil r
    assert_equal 3, r[:score]
    assert_includes r[:detail], "catch_spam"
    assert_nil report(@a, "flags:reward_level")         # under threshold
  end

  # Badge authority B1: one badge no win explains is worth a look (flagged only when the
  # server could own every badge, once per frame).
  def test_one_unexplained_badge_is_reported
    @det.record_flag(@a, :badge_unexplained)
    assert_equal 1, @det.sweep
    refute_nil report(@a, "flags:badge_unexplained")
  end

  # ... a badge no replay can prove, from the second (one battle begun offline is honest)
  def test_two_unprovable_badges_are_reported
    @det.record_flag(@a, :badge_unprovable)
    assert_equal 0, @det.sweep
    @det.record_flag(@a, :badge_unprovable)
    assert_equal 1, @det.sweep
    refute_nil report(@a, "flags:badge_unprovable")
  end

  # --- sweep: provenance mix (fabricated wild-table mons) ----------------------------
  def test_sweep_reports_fabricated_wild_provenance
    5.times { mon(@a, "PIDGEY", "client") }             # 5 client-origin wild-table mons
    mon(@a, "MEWTWO", "client")                          # a non-wild species -> ignored
    mon(@a, "PIDGEY", "wild_caught")                     # 1 legit wild_caught
    assert_operator @det.sweep, :>=, 1

    r = report(@a, "fabricated_wild")
    refute_nil r
    assert_equal 5, r[:score]
    assert_includes r[:detail], "vs 1 wild_caught"
  end

  def test_provenance_not_reported_when_wild_caught_outnumbers
    5.times { mon(@a, "PIDGEY", "client") }
    6.times { mon(@a, "RATTATA", "wild_caught") }        # more legit than fabricated
    @det.sweep
    assert_nil report(@a, "fabricated_wild")
  end

  def test_provenance_needs_the_minimum_volume
    4.times { mon(@a, "PIDGEY", "client") }              # below FABRICATED_WILD_MIN (5)
    @det.sweep
    assert_nil report(@a, "fabricated_wild")
  end

  # The report blames the MINTER (issuer), not a trade RECIPIENT: A fabricates 5 mons and
  # trades them to innocent B (owner=B, issuer=A). A is flagged; B is not (anti-grief).
  def test_fabricated_wild_blames_the_minter_not_the_recipient
    5.times { mon(@b, "PIDGEY", "client", issuer: @a) }  # owned by B, minted by A
    @det.sweep
    refute_nil report(@a, "fabricated_wild")
    assert_nil report(@b, "fabricated_wild")
  end

  # Gift/hatched eggs of a wild species are legitimately client-minted -> excluded.
  def test_gift_eggs_are_excluded
    5.times { mon(@a, "PIDGEY", "client", egg: true) }
    @det.sweep
    assert_nil report(@a, "fabricated_wild")
  end

  # --- sweep is idempotent (dedup) ---------------------------------------------------
  def test_sweep_is_idempotent
    4.times { @det.record_flag(@a, :catch_spam) }
    @det.sweep
    @det.record_flag(@a, :catch_spam)                    # count now 5
    @det.sweep
    assert_equal 1, @db[:anomaly_reports].where(account_id: @a, kind: "flags:catch_spam").count
    assert_equal 5, report(@a, "flags:catch_spam")[:score]   # refreshed, not duplicated
  end

  # --- open_reports excludes reviewed ------------------------------------------------
  def test_open_reports_excludes_reviewed
    3.times { @det.record_flag(@a, :catch_spam) }
    @det.sweep
    assert_equal 1, @det.open_reports.length
    @db[:anomaly_reports].where(account_id: @a, kind: "flags:catch_spam").update(reviewed_at: Time.now)
    assert_equal 0, @det.open_reports.length
  end

  def test_empty_sweep_writes_nothing
    assert_equal 0, @det.sweep
    assert_equal 0, @db[:anomaly_reports].count
  end

  # --- D7 part 3: evasion-by-silence (caught seeded encounters, no battle record) -----

  def seeded_caught_roll(account, pid, age_sec: 7_200)
    t = Time.now - age_sec
    @db[:encounter_rolls].insert(account_id: account, species: "PIDGEY", level: 5, pid: pid,
                                 iv: Sequel.pg_jsonb([0] * 6), shiny: false, map: 5, enctype: "Land",
                                 battle_seed: 10_000 + pid, caught_at: t, created_at: t)
  end

  def capability_record(account)
    @db[:battle_records].insert(account_id: account, mode: "on", record: Sequel.blob("x"),
                                replay_status: "match", created_at: Time.now)
  end

  def test_rng_silence_reports_record_capable_silent_accounts
    capability_record(@a)                                  # the client CAN send records...
    5.times { |i| seeded_caught_roll(@a, 100 + i) }        # ...yet 5 caught mints have none
    assert_equal 1, @det.sweep
    r = report(@a, "rng_silent")
    assert r, "silent account should be reported"
    assert_equal 5, r[:score]
  end

  def test_rng_silence_ignores_accounts_that_never_sent_a_record
    6.times { |i| seeded_caught_roll(@b, 200 + i) }        # an old client without the plugin
    assert_equal 0, @det.sweep
    assert_nil report(@b, "rng_silent")
  end

  def test_rng_silence_respects_grace_and_threshold
    capability_record(@a)
    4.times { |i| seeded_caught_roll(@a, 300 + i) }        # under SILENT_SEEDED_MIN
    seeded_caught_roll(@a, 399, age_sec: 60)               # 5th is inside the grace window
    assert_equal 0, @det.sweep
    assert_nil report(@a, "rng_silent")
  end

  # --- D8: claim-evasion (condemned caught roll, uid never minted) --------------------

  def condemned_unclaimed_roll(account, pid, condemned_age: 7_200)
    t = Time.now - condemned_age
    @db[:encounter_rolls].insert(account_id: account, species: "PIDGEY", level: 5, pid: pid,
                                 iv: Sequel.pg_jsonb([0] * 6), shiny: false, map: 5, enctype: "Land",
                                 battle_seed: 20_000 + pid, caught_at: t, condemned_at: t,
                                 claimed_monster_uid: nil, created_at: t)
  end

  def test_claim_evasion_reports_condemned_never_minted_catches
    3.times { |i| condemned_unclaimed_roll(@a, 400 + i) }
    assert_equal 1, @det.sweep
    r = report(@a, "resim_claim_evasion")
    assert r
    assert_equal 3, r[:score]
  end

  def test_claim_evasion_ignores_claimed_or_within_grace
    condemned_unclaimed_roll(@a, 500)
    condemned_unclaimed_roll(@a, 501)
    condemned_unclaimed_roll(@a, 502, condemned_age: 60)          # inside grace -> not counted
    # one of them DID mint its uid -> not evasion
    @db[:encounter_rolls].where(account_id: @a, pid: 500).update(claimed_monster_uid: 999)
    assert_equal 0, @det.sweep                                    # only 1 qualifying < MIN(3)
    assert_nil report(@a, "resim_claim_evasion")
  end
end
