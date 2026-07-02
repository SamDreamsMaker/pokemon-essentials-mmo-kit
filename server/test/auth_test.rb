require "minitest/autorun"
require "sequel"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/password"
require "pemk/accounts"
require "pemk/sessions"

# Auth data-access tests against the real Postgres (DATABASE_URL). Each test
# starts from an empty accounts table (delete cascades to sessions).
class AuthTest < Minitest::Test
  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
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

  def test_register_then_authenticate
    id = @accounts.create(username: "Ash", password: "pikapika123")
    assert_kind_of Integer, id
    acct, err = @accounts.authenticate("Ash", "pikapika123")
    assert_nil err
    assert_equal id, acct[:id]
  end

  def test_duplicate_username_rejected_case_insensitively
    assert @accounts.create(username: "Misty", password: "password1")
    assert_nil @accounts.create(username: "Misty", password: "password2")
    assert_nil @accounts.create(username: "MISTY", password: "password3") # citext
  end

  def test_malformed_input_raises
    assert_raises(ArgumentError) { @accounts.create(username: "ab", password: "password1") }
    assert_raises(ArgumentError) { @accounts.create(username: "Ash", password: "short") }
    assert_raises(ArgumentError) { @accounts.create(username: "bad name!", password: "password1") }
  end

  def test_lockout_after_five_failures
    @accounts.create(username: "Brock", password: "onixrock1")
    5.times { assert_equal :bad_password, @accounts.authenticate("Brock", "nope").last }
    assert_equal :locked, @accounts.authenticate("Brock", "onixrock1").last # locked despite correct pw
  end

  def test_unknown_user
    assert_equal :not_found, @accounts.authenticate("Ghost", "whatever").last
  end

  def test_session_issue_resolve_revoke
    id = @accounts.create(username: "Gary", password: "oakoakoak1")
    token = @sessions.issue(id, remote_addr: "127.0.0.1")
    assert_equal 64, token.length
    assert_equal id, @sessions.resolve(token)
    assert_nil @sessions.resolve("deadbeef")
    @sessions.revoke(token)
    assert_nil @sessions.resolve(token)
  end

  def test_session_absolute_expiry
    id = @accounts.create(username: "Oak", password: "professor1")
    token = @sessions.issue(id, now: Time.now - (40 * 24 * 3600))
    assert_nil @sessions.resolve(token)
  end
end
