require "minitest/autorun"
require "sequel"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/forget"
require "pemk/sessions"
require "pemk/bans"

# The right to be forgotten: the account's personal data and its own state go, what
# other players' records and the audit rely on stays, and every table that names an
# account is on one list or the other.
class ForgetTest < Minitest::Test
  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[monster_transfers monsters enforcement_events].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @id = @db[:accounts].insert(email: "gone@t.co", username: "gone", password_hash: "x", status: "active",
                                created_at: Time.now, last_login_at: Time.now)
    @forget = PEMK::Forget.new(@db)
  end

  def teardown
    @db&.disconnect
  end

  # A new table naming an account must be told what to do with it.
  def test_every_table_naming_an_account_is_on_a_list
    naming = @db.tables.select { |t| @db.foreign_key_list(t).any? { |fk| fk[:table] == :accounts } }.sort
    assert_equal naming, (PEMK::Forget::GONE + PEMK::Forget::KEPT).sort, "every table on one list"
    assert_empty PEMK::Forget::GONE & PEMK::Forget::KEPT
  end

  def test_what_goes_and_what_stays
    PEMK::Sessions.new(@db).issue(@id)
    @db[:characters].insert(account_id: @id, save_blob: Sequel.blob("the player's name is in here"), updated_at: Time.now)
    @db[:economy_balances].insert(account_id: @id, field: "money", balance: 3000, last_seq: 1)
    @db[:badge_baselines].insert(account_id: @id, mask: 1, taken_at: Time.now) rescue nil
    assert_equal :forgotten, @forget.forget(@id, by: "op")
    acct = @db[:accounts].where(id: @id).first
    assert_nil acct[:email]
    assert_equal ["forgotten-#{@id}", "forgotten", "forgotten"], acct.values_at(:username, :password_hash, :status)
    assert_nil acct[:last_login_at]
    refute_nil acct[:forgotten_at]
    assert_equal 0, @db[:characters].where(account_id: @id).count, "the save is gone"
    assert_equal 0, @db[:sessions].where(account_id: @id).count, "the sessions (their addresses) are gone"
    assert_equal 3000, @db[:economy_balances].where(account_id: @id).get(:balance), "the ledger stays"
    refute_nil PEMK::Bans.new(@db).active(@id), "banned: the server lets it go and refuses it"
    assert @forget.forgotten?(@id)
    assert_equal [@id], @forget.forgotten_among([@id, @id + 1])
    @db[:accounts].insert(email: "gone@t.co", password_hash: "y", status: "active", created_at: Time.now)   # the address is free again
  end

  def test_forgetting_again_only_purges
    assert_equal :forgotten, @forget.forget(@id, by: "op")
    at = @db[:accounts].where(id: @id).get(:forgotten_at)
    @db[:characters].insert(account_id: @id, save_blob: Sequel.blob("a save pushed late"), updated_at: Time.now)
    assert_equal :already, @forget.forget(@id, by: "op")
    assert_equal at, @db[:accounts].where(id: @id).get(:forgotten_at), "the first date stands"
    assert_equal 1, @db[:account_bans].where(account_id: @id).count, "one ban row"
    assert_equal 0, @db[:characters].where(account_id: @id).count, "the late save is gone"
    assert_nil @forget.forget(@id + 1_000_000, by: "op")
  end
end
