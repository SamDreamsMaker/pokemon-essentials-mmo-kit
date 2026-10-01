require "minitest/autorun"
require "sequel"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/world_data"
require "pemk/badge_audit"

# Badge authority B1 (docs/BADGE-AUTHORITY-DESIGN.md): a badge a client reports is judged
# by the battle that gives it - explained by a proven win over its trainer, pending while
# that win's proof is to come, refused otherwise.
class BadgeAuditTest < Minitest::Test
  BROCK = ["LEADER_Brock", "Brock", 0, 10, 3].freeze

  def world(badge_sources)
    doc = { "schema_version" => 3, "trainer_marks" => true,
            "maps" => { "10" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [],
                                  "trainers" => [{ "event_id" => 3, "x" => 6, "y" => 5, "type" => "LEADER_Brock",
                                                   "name" => "Brock", "version" => 0 }] } } }
    doc["badge_sources"] = badge_sources if badge_sources
    @file = Tempfile.new(["world", ".json"])
    @file.write(JSON.generate(doc))
    @file.flush
    PEMK::WorldData.new(@file.path)
  end

  SOURCES = { "list" => [{ "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [BROCK[0, 3]] },
                         { "badge" => 1, "map" => 3, "event" => 7, "page" => 0 }],
              "unknown" => [] }.freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:battle_records].delete
    @db[:money_claims].delete
    @db[:badge_baselines].delete
    @db[:trainer_battles].delete
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @me = @db[:accounts].insert(email: "badge@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @audit = PEMK::BadgeAudit.new(@db, world(SOURCES))
  end

  def teardown
    @db&.disconnect
    @file&.close!
  end

  # A trainer prize claim; +record+: its battle's won record is on its seed.
  def claim(nonce, trainers: [BROCK], proof: nil, seeded: true, voided: false, kind: "trainer", verdict: "held",
            record: false, account: @me)
    row = nil
    if seeded
      row = @db[:trainer_battles].insert(account_id: account, map_id: 10, event_id: 3, tr_type: "LEADER_Brock",
                                         tr_name: "Brock", tr_version: 0, seed: rand(1 << 40) + 1, issued_at: Time.now,
                                         state: "closed")
    end
    if record
      @db[:battle_records].insert(account_id: account, trainer_battle_id: row, mode: "on", record: Sequel.blob("x"),
                                  outcome: 1, created_at: Time.now, replay_status: record == true ? "walk_ok" : record)
    end
    @db[:money_claims].insert(account_id: account, nonce: nonce, kind: kind, verdict: verdict, mode: "on", amount: 1400,
                              accepted: 1400, map: 10, trainers: trainers.to_json, created_at: Time.now,
                              trainer_battle_id: row, proof: proof, voided_at: voided ? Time.now : nil)
  end

  def verdict(mask) = @audit.judge(@me, mask).map { |b, v, _| [b, v] }
  def why(mask) = @audit.judge(@me, mask).map(&:last)

  def test_a_badge_is_judged_by_the_battle_that_gives_it
    assert_equal [[0, :refused], [1, :refused], [2, :refused]], verdict(0b111)
    assert_equal ["no win over LEADER_Brock Brock was claimed",
                  "no battle gives it",   # the house's debug NPC: no battle
                  "nothing the exports read gives it"], why(0b111)

    claim(1, voided: true, seeded: false)   # a fresh login voids it, and unlinks it
    assert_equal [[0, :refused]], verdict(1), "a voided claim explains nothing"
    claim(2, verdict: "away", record: true)
    assert_equal [[0, :refused]], verdict(1), "a claim away from its trainer explains nothing"
    claim(3, kind: "payday", record: true)
    assert_equal [[0, :refused]], verdict(1), "Pay Day's coins come won or lost"
    claim(4)
    assert_equal ["the win over LEADER_Brock Brock has no record"], why(1), "a seed and a claim, but no battle"
    claim(5, proof: "refuted", record: true)
    assert_equal ["the win over LEADER_Brock Brock is refuted"], why(1)
    claim(6, seeded: false)
    assert_equal [[0, :unprovable]], verdict(1)
    assert_equal ["the win over LEADER_Brock Brock was claimed with no seed"], why(1)
    claim(7, record: true)
    assert_equal [[0, :pending]], verdict(1), "its won record waits for its replay"
    assert_equal ["the win over LEADER_Brock Brock waits for its replay"], why(1)
    claim(8, proof: "proven")
    assert_equal [[0, :explained]], verdict(1)
    assert_equal [0], @audit.wins_of(@me, 8)
    assert_equal [], verdict(0), "nothing new: nothing to judge"
  end

  def test_a_win_the_harness_cannot_replay_is_unprovable
    claim(1, proof: "unprovable", record: true)
    assert_equal ["the win over LEADER_Brock Brock could not be replayed"], why(1)
    assert_equal [[0, :unprovable]], verdict(1)
  end

  # A record whose draws the seed walk refuted as it came is no win waiting for its replay.
  def test_a_record_not_drawn_from_its_seed_is_no_win
    claim(1, record: "walk_mismatch")
    assert_equal [[0, :refused]], verdict(1)
    assert_equal ["the win over LEADER_Brock Brock has a record not drawn from its seed (walk_mismatch)"], why(1)
    claim(2, record: "pending")
    assert_equal [[0, :pending]], verdict(1)
  end

  # B2 grants a badge at its win's proof: a fresh login voiding the claim after takes it not.
  def test_a_voided_claim_proven_still_explains
    claim(1, voided: true, seeded: false, proof: "proven")
    assert_equal [[0, :explained]], verdict(1)
  end

  def test_the_first_baseline_stays
    assert_nil @audit.baseline_of(@me), "never judged"
    assert_equal 0b101, @audit.baseline(@me, 0b101)
    assert_equal 0b101, @audit.baseline(@me, 0b111), "the first one stays"
    assert_equal 0b101, @audit.baseline_of(@me)
  end

  def test_the_wins_a_claim_gives
    claim(1, proof: "proven")
    claim(2, proof: "proven", verdict: "away")
    claim(3, proof: "proven", kind: "payday")
    assert_equal [0], @audit.wins_of(@me, 1)
    assert_equal [], @audit.wins_of(@me, 2), "a claim away from its trainer gives nothing"
    assert_equal [], @audit.wins_of(@me, 3), "nor Pay Day's"
    assert_equal [0], @audit.wins_in(@db[:money_claims].where(nonce: 3).first), "what its trainers' win gives"
  end

  def test_bits_of
    assert_equal [1, 3], @audit.bits_of(0b1010)
    assert_equal [], @audit.bits_of(0)
    assert_equal [], @audit.bits_of(-5)   # ...11011: its low bits are set
    assert_equal [], @audit.bits_of("1")
  end

  def test_an_export_from_before_the_badges_explains_nothing
    audit = PEMK::BadgeAudit.new(@db, world(nil))
    claim(1, proof: "proven")
    assert_equal [[0, :refused, "the exports do not say what gives badges"]], audit.judge(@me, 1)
  end

  def test_another_trainer_s_win_gives_not_this_badge
    claim(1, trainers: [["CAMPER", "Liam", 0, 10, 4]], proof: "proven")
    assert_equal [[0, :refused]], verdict(1)
  end

  def test_another_account_s_win_explains_nothing
    claim(1, proof: "proven")
    other = @db[:accounts].insert(email: "other@t.co", password_hash: "x", status: "active", created_at: Time.now)
    assert_equal [[0, :refused]], @audit.judge(other, 1).map { |b, v, _| [b, v] }
    assert_equal [], @audit.wins_of(other, 1)
    claim(2, account: other, record: true)   # its own win, waiting for its replay
    assert_equal [[0, :pending]], @audit.judge(other, 1).map { |b, v, _| [b, v] }
    assert_equal [[0, :explained]], verdict(1)
  end

  def test_a_lost_battle_s_record_is_no_win
    claim(1)
    row = @db[:money_claims].where(nonce: 1).get(:trainer_battle_id)
    @db[:battle_records].insert(account_id: @me, trainer_battle_id: row, mode: "on", record: Sequel.blob("x"),
                                outcome: 2, created_at: Time.now)
    assert_equal [[0, :refused]], verdict(1)
  end
end
