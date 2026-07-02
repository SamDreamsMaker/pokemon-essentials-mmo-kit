require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Monster UID registry: idempotent nonce-keyed minting (the make-or-break) and the
# party projection cross-check (flag-never-reject).
class MonstersTest < Minitest::Test
  CAPS = { uid_req_max: 64, party_max: 6, level_max: 100 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monsters].delete          # no cascade from accounts (deliberate) -> clear first
    @db[:accounts].delete
    @acct  = @db[:accounts].insert(email: "mon@x.co",  password_hash: "x", status: "active", created_at: Time.now)
    @other = @db[:accounts].insert(email: "mon2@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @mon  = PEMK::Monsters.new(@db, CAPS, logger: ->(m) { @logs << m })
  end

  def teardown
    @db&.disconnect
  end

  def entry(tmp, species = :PIKACHU, level = 12, pid = 3_735_928_559, egg = false)
    { tmp: tmp, species: species, level: level, pid: pid, egg: egg }
  end

  def test_fresh_batch_mints_and_grants
    status, grants = @mon.mint_batch(@acct, [entry(101), entry(102, :EEVEE, 5)])
    assert_equal :ack, status
    assert_equal [101, 102], grants.map { |g| g[:tmp] }
    assert_equal 2, @db[:monsters].count
    row = @db[:monsters].where(client_nonce: 101).first
    assert_equal "PIKACHU", row[:species]
    assert_equal @acct, row[:owner_account_id]
    assert_equal @acct, row[:issuer_account_id]
    assert_equal "active", row[:status]
  end

  def test_replayed_batch_returns_same_uids_no_new_rows
    _, first  = @mon.mint_batch(@acct, [entry(101), entry(102, :EEVEE, 5)])
    _, replay = @mon.mint_batch(@acct, [entry(101), entry(102, :EEVEE, 5)])
    assert_equal first.sort_by { |g| g[:tmp] }, replay.sort_by { |g| g[:tmp] }   # SAME uids
    assert_equal 2, @db[:monsters].count                                          # no duplicate mint
  end

  def test_mixed_batch_mints_only_the_new
    _, first = @mon.mint_batch(@acct, [entry(101)])
    _, mixed = @mon.mint_batch(@acct, [entry(101), entry(103, :MEW, 50)])
    assert_equal 2, @db[:monsters].count
    assert_equal first[0][:uid], mixed.find { |g| g[:tmp] == 101 }[:uid]
  end

  def test_same_nonce_different_account_is_a_distinct_row
    _, a = @mon.mint_batch(@acct,  [entry(777)])
    _, b = @mon.mint_batch(@other, [entry(777)])
    refute_equal a[0][:uid], b[0][:uid]   # scoped to the issuer, not global
    assert_equal 2, @db[:monsters].count
  end

  def test_bad_entries_are_skipped_not_minted
    _, grants = @mon.mint_batch(@acct, [
      entry(101),
      entry(-5),                                   # tmp not positive
      entry(102, :EEVEE, 0),                       # level out of range
      entry(103, :EEVEE, 101),                     # level over cap
      { tmp: 104, species: 42, level: 5, pid: 1, egg: false }, # species not Symbol/String
      "junk"                                       # not a Hash
    ])
    assert_equal [101], grants.map { |g| g[:tmp] }
    assert_equal 1, @db[:monsters].count
  end

  def test_oversized_or_malformed_frame_rejected
    assert_equal [:rej, ["bad_shape"]], @mon.mint_batch(@acct, "junk")
    assert_equal [:rej, ["bad_shape"]], @mon.mint_batch(@acct, Array.new(65) { |i| entry(i + 1) })
    assert_equal 0, @db[:monsters].count
  end

  # --- party projection ---------------------------------------------------------

  def proj(uid, species = :PIKACHU, level = 12)
    { uid: uid, species: species, level: level }
  end

  def test_apply_party_records_clean_snapshot
    _, grants = @mon.mint_batch(@acct, [entry(101)])
    uid = grants[0][:uid]
    status, flags = @mon.apply_party(@acct, [proj(uid), proj(nil, :EEVEE, 5)], 1)
    assert_equal :ack, status
    assert_empty flags                     # nil uid = mint in flight, never flagged
    row = @db[:party_snapshots].where(account_id: @acct).first
    assert_equal false, row[:flagged]
    assert_equal 1, row[:last_seq]
    assert_equal 2, row[:party].to_a.size
  end

  def test_dup_and_stale_seq_do_not_mutate
    @mon.apply_party(@acct, [proj(nil)], 3)
    assert_equal [:dup, []], @mon.apply_party(@acct, [proj(nil, :MEW)], 3)
    assert_equal [:dup, []], @mon.apply_party(@acct, [proj(nil, :MEW)], 2)
    assert_equal 3, @mon.mon_seq(@acct)
  end

  def test_foreign_uid_flags_projection_and_monster_row
    _, grants = @mon.mint_batch(@other, [entry(500)])   # minted by the OTHER account
    stolen = grants[0][:uid]
    status, flags = @mon.apply_party(@acct, [proj(stolen)], 1)
    assert_equal :ack, status                            # flag, never reject
    assert_includes flags, "foreign_uid"
    snap = @db[:party_snapshots].where(account_id: @acct).first
    assert_equal true, snap[:flagged]                    # adopted even when flagged
    mon = @db[:monsters].where(id: stolen).first
    assert_equal true, mon[:flagged]
    sightings = mon[:flags].to_a
    assert_equal 1, sightings.size
    assert_equal @acct, sightings[0]["seen_by"]
    assert_equal "foreign_uid", sightings[0]["kind"]
  end

  def test_dup_in_party_and_unknown_uid_flagged
    _, grants = @mon.mint_batch(@acct, [entry(101)])
    uid = grants[0][:uid]
    _, flags = @mon.apply_party(@acct, [proj(uid), proj(uid, :RAICHU, 30)], 1)
    assert_includes flags, "dup_in_party"
    _, flags2 = @mon.apply_party(@acct, [proj(999_999_999)], 2)
    assert_includes flags2, "unknown_uid"
  end

  def test_level_species_drift_never_flagged
    _, grants = @mon.mint_batch(@acct, [entry(101, :PIKACHU, 12)])
    uid = grants[0][:uid]
    _, flags = @mon.apply_party(@acct, [proj(uid, :RAICHU, 36)], 1)   # evolved + leveled: normal play
    assert_empty flags
  end

  def test_bad_party_shape_rejected
    assert_equal [:rej, ["bad_shape"]], @mon.apply_party(@acct, "junk", 1)
    assert_equal [:rej, ["bad_shape"]], @mon.apply_party(@acct, Array.new(7) { proj(nil) }, 1)
    assert_equal [:rej, ["bad_shape"]], @mon.apply_party(@acct, [{ uid: "x", species: :A, level: 1 }], 1)
  end

  def test_mon_seq_defaults_to_zero
    assert_equal 0, @mon.mon_seq(@acct)
  end
end
