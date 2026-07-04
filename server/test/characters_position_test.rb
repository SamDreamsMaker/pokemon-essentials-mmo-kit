require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer B server-owned spawn: the character store persists the last SERVER-
# validated position and returns it at login, and a position-less save must NEVER
# wipe a previously-stored position.
class CharactersPositionTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete   # cascades to characters
    @acct = @db[:accounts].insert(email: "chr@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @chr  = PEMK::Characters.new(@db)
  end

  def teardown
    @db&.disconnect
  end

  def test_store_persists_and_loads_position
    @chr.store(@acct, blob: "abc", position: [5, 10, 12])
    assert_equal [5, 10, 12], @chr.load_position(@acct)
  end

  def test_no_position_stored_is_nil
    @chr.store(@acct, blob: "abc")
    assert_nil @chr.load_position(@acct)
  end

  def test_position_update_overwrites
    @chr.store(@acct, blob: "abc", position: [5, 10, 12])
    @chr.store(@acct, blob: "def", position: [7, 1, 2])
    assert_equal [7, 1, 2], @chr.load_position(@acct)
  end

  def test_position_less_save_keeps_prior_position
    @chr.store(@acct, blob: "abc", position: [5, 10, 12])
    @chr.store(@acct, blob: "def")   # no position -> must NOT wipe it
    assert_equal [5, 10, 12], @chr.load_position(@acct)
    assert_equal "def", @db[:characters].where(account_id: @acct).get(:save_blob).to_s
  end

  def test_invalid_position_ignored
    @chr.store(@acct, blob: "abc", position: [5, 10])       # wrong arity
    assert_nil @chr.load_position(@acct)
    @chr.store(@acct, blob: "abc", position: [5, "x", 1])   # non-integer
    assert_nil @chr.load_position(@acct)
  end
end
