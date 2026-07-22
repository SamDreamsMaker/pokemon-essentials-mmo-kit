require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer D D3.2: the persisted encounter-roll claim-check (record -> mark_caught ->
# claim) and the Monsters provenance binding (origin wild_caught / wild / client).
class EncounterRollsTest < Minitest::Test
  MINT = { "species" => "SPINARAK", "level" => 12, "pid" => 12_345,
           "iv" => [31, 20, 15, 10, 5, 0], "shiny" => false }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:encounter_rolls].delete rescue nil
    @db[:pickups].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "er-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "er-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @rolls = PEMK::EncounterRolls.new(@db)
    @logs  = []
    @mons  = PEMK::Monsters.new(@db, { uid_req_max: 64, party_max: 6, level_max: 100 },
                                logger: ->(m) { @logs << m }, rolls: @rolls)
  end

  def teardown
    @db&.disconnect
  end

  def entry(tmp: 1, pid: 12_345, species: :SPINARAK, level: 12)
    { tmp: tmp, species: species, level: level, pid: pid, egg: false }
  end

  # --- the roll lifecycle -----------------------------------------------------------
  def test_record_claim_and_caught_stamp
    @rolls.record(@a, MINT, 5, "LandNight")
    assert_equal :wild, @rolls.claim(@a, "SPINARAK", 12_345)          # claimed, not caught
    assert_nil @rolls.claim(@a, "SPINARAK", 12_345)                   # already claimed

    @rolls.record(@a, MINT, 5, "LandNight")                            # a second roll
    assert @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    assert_equal :wild_caught, @rolls.claim(@a, "SPINARAK", 12_345)
  end

  def test_claim_is_account_scoped_and_identity_exact
    @rolls.record(@a, MINT, 5, "Land")
    assert_nil @rolls.claim(@b, "SPINARAK", 12_345)                   # another account
    assert_nil @rolls.claim(@a, "RATTATA", 12_345)                    # wrong species
    assert_nil @rolls.claim(@a, "SPINARAK", 99_999)                   # wrong pid
    assert_equal :wild, @rolls.claim(@a, "SPINARAK", 12_345)          # species+pid match works
  end

  # Level is NOT part of the claim key: a mon that leveled between catch and (a delayed)
  # first sweep still claims its roll instead of mislabeling "client".
  def test_claim_tolerates_level_drift
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    e = entry(pid: 12_345, level: 14)                                  # leveled up before the sweep
    _, grants = @mons.mint_batch(@a, [e])
    assert_equal "wild_caught", @db[:monsters].where(id: grants[0][:uid]).get(:origin)
  end

  # With two matching rolls, claim prefers the CAUGHT one (never coin-flips to :wild).
  def test_claim_prefers_caught_rolls
    @rolls.record(@a, MINT, 5, "Land")                                 # uncaught roll (older)
    @rolls.record(@a, MINT, 5, "Land")                                 # second roll ...
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)                     # ... stamped (newest uncaught)
    assert_equal :wild_caught, @rolls.claim(@a, "SPINARAK", 12_345)
  end

  # Boot retention: stale never-fought rolls are pruned; caught/claimed rows are kept.
  def test_prune_drops_only_stale_unfought_rolls
    old = Time.now - (10 * 86_400)
    @rolls.record(@a, MINT, 5, "Land", now: old)                       # stale, never fought
    @rolls.record(@a, MINT.merge("pid" => 2), 5, "Land", now: old)     # stale but caught
    @rolls.mark_caught(@a, "SPINARAK", 12, 2, now: old)
    @rolls.record(@a, MINT.merge("pid" => 3), 5, "Land")               # fresh
    assert_equal 1, @rolls.prune
    pids = @db[:encounter_rolls].select_map(:pid).sort
    assert_equal [2, 3], pids
  end

  def test_mark_caught_needs_an_uncaught_roll
    refute @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)             # nothing recorded
    @rolls.record(@a, MINT, 5, "Land")
    assert @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    refute @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)             # already stamped
  end

  # --- provenance binding in the UID mint ---------------------------------------------
  def test_mint_with_a_caught_roll_is_wild_caught
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, grants = @mons.mint_batch(@a, [entry])
    origin = @db[:monsters].where(id: grants[0][:uid]).get(:origin)
    assert_equal "wild_caught", origin
    assert_nil @db[:encounter_rolls].where(account_id: @a, claimed_at: nil).first   # roll claimed
    assert(@logs.any? { |l| l.include?("wild_caught=1") }, @logs.inspect)
  end

  def test_mint_without_a_roll_is_client
    _, grants = @mons.mint_batch(@a, [entry(pid: 777)])               # starter/gift/egg case
    assert_equal "client", @db[:monsters].where(id: grants[0][:uid]).get(:origin)
  end

  def test_replay_keeps_the_original_origin
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, g1 = @mons.mint_batch(@a, [entry])
    _, g2 = @mons.mint_batch(@a, [entry])                              # same nonce -> replay
    assert_equal g1[0][:uid], g2[0][:uid]
    assert_equal "wild_caught", @db[:monsters].where(id: g1[0][:uid]).get(:origin)
  end

  def test_save_copied_clone_labels_client
    @rolls.record(@a, MINT, 5, "Land")
    @rolls.mark_caught(@a, "SPINARAK", 12, 12_345)
    _, g1 = @mons.mint_batch(@a, [entry(tmp: 1)])                      # the original claims the roll
    _, g2 = @mons.mint_batch(@a, [entry(tmp: 2)])                      # the CLONE (new nonce, same pid)
    assert_equal "wild_caught", @db[:monsters].where(id: g1[0][:uid]).get(:origin)
    assert_equal "client",      @db[:monsters].where(id: g2[0][:uid]).get(:origin)
  end

  def test_mint_without_rolls_collaborator_stays_nil
    plain = PEMK::Monsters.new(@db, { uid_req_max: 64, party_max: 6, level_max: 100 })
    _, grants = plain.mint_batch(@a, [entry(tmp: 9, pid: 42)])
    assert_nil @db[:monsters].where(id: grants[0][:uid]).get(:origin)   # legacy behavior
  end
end
