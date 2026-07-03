require "minitest/autorun"
require "sequel"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/password"
require "pemk/accounts"
require "pemk/sessions"

# Auth data-access tests against the real Postgres (DATABASE_URL). Accounts are
# identified by email. Each test starts from an empty table (delete cascades).
class AuthTest < Minitest::Test
  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:accounts].delete
    @accounts = PEMK::Accounts.new(@db)
    @sessions = PEMK::Sessions.new(@db)
  end

  def teardown
    @db&.disconnect
  end

  def test_password_hash_and_verify
    h = PEMK::Password.hash("correct horse battery staple")
    assert PEMK::Password.verify("correct horse battery staple", h)
    refute PEMK::Password.verify("wrong", h)
    refute PEMK::Password.verify("x", "not-a-bcrypt-hash")
  end

  def test_register_then_authenticate_by_email
    id = @accounts.create(email: "ash@pallet.town", password: "pikapika123", username: "Ash")
    assert_kind_of Integer, id
    acct, err = @accounts.authenticate("ash@pallet.town", "pikapika123")
    assert_nil err
    assert_equal id, acct[:id]
  end

  def test_username_is_optional
    id = @accounts.create(email: "nohandle@x.co", password: "password1")
    assert_kind_of Integer, id
  end

  def test_duplicate_email_rejected_case_insensitively
    assert @accounts.create(email: "Misty@x.co", password: "password1")
    assert_nil @accounts.create(email: "misty@x.co", password: "password2") # citext
  end

  def test_malformed_input_raises
    assert_raises(ArgumentError) { @accounts.create(email: "", password: "password1") }
    assert_raises(ArgumentError) { @accounts.create(email: "notanemail", password: "password1") }
    assert_raises(ArgumentError) { @accounts.create(email: "ok@x.co", password: "short") }
    assert_raises(ArgumentError) { @accounts.create(email: "ok2@x.co", password: "password1", username: "bad name!") }
  end

  def test_lockout_after_five_failures
    @accounts.create(email: "brock@x.co", password: "onixrock1")
    5.times { assert_equal :bad_password, @accounts.authenticate("brock@x.co", "nope").last }
    assert_equal :locked, @accounts.authenticate("brock@x.co", "onixrock1").last
  end

  def test_unknown_email
    assert_equal :not_found, @accounts.authenticate("ghost@x.co", "whatever").last
  end

  def test_session_issue_resolve_revoke
    id = @accounts.create(email: "gary@x.co", password: "oakoakoak1")
    token = @sessions.issue(id, remote_addr: "127.0.0.1")
    assert_equal 64, token.length
    assert_equal id, @sessions.resolve(token)
    assert_nil @sessions.resolve("deadbeef")
    @sessions.revoke(token)
    assert_nil @sessions.resolve(token)
  end

  def test_session_absolute_expiry
    id = @accounts.create(email: "oak@x.co", password: "professor1")
    token = @sessions.issue(id, now: Time.now - (40 * 24 * 3600))
    assert_nil @sessions.resolve(token)
  end
end
