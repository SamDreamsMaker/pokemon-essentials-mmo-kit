require "minitest/autorun"
require "socket"
require "timeout"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# The right to be forgotten, on a live server: the forgotten account is let go within
# the ban sweep, a save of its that was queued behind other work lands after the
# operator's purge - and is purged again once that work is done; its email names nobody
# and its token is refused.
class ServerForgetTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[monster_transfers monsters enforcement_events].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
    @server = PEMK::Server.new(logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def logs
    @seen ||= []
    @seen << @logs.pop until @logs.empty?
    @seen
  end

  def send_env(s, e, body = nil) = s.write(W.encode_split(e, body))

  def recv_type(s, *types, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        env = W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
        return env if types.include?(env[:type])
      end
    end
  end

  def login(email)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1", caps: %w[save_ack] })
    [s, recv_type(s, :login_ok, :login_err)]
  end

  def wait_until(what, seconds)
    deadline = Time.now + seconds
    until yield
      flunk "#{what}: not within #{seconds}s" if Time.now > deadline

      sleep 0.1
    end
  end

  # The account's mailbox busy for +seconds+ (queued from the reactor, as the server does).
  def hold(id, seconds)
    done = Queue.new
    @server.instance_variable_get(:@reactor).post do
      @server.instance_variable_get(:@mailbox).submit(id) { sleep seconds }
      done << true
    end
    Timeout.timeout(3) { done.pop }
  end

  def test_a_forgotten_player_is_let_go_and_a_late_save_purged
    s, lo = login("gone@t.co")
    id = lo[:account_id]
    token = lo[:token]
    hold(id, 2)                                                            # work ahead of its save
    send_env(s, { type: :save, trainer_id: 7 }, "the player's name is in here")   # queued behind it
    sleep 0.3
    assert_equal :forgotten, PEMK::Forget.new(@db).forget(id, by: "op")   # the console, meanwhile
    assert_equal 0, @db[:characters].where(account_id: id).count
    @server.instance_variable_set(:@last_ban_sweep, nil)                  # the next tick sweeps
    told = recv_type(s, :banned, timeout: PEMK::Server::BAN_SWEEP_SEC + 5)
    assert_equal PEMK::Forget::REASON, told[:note], "let go, told why"
    assert_nil Timeout.timeout(5) { s.read(1) }, "and its connection closes"
    wait_until("the late save purged", 10) do
      logs.any? { |l| l.match?(/account #{id} forgotten - 1 characters purged after its last work/) }
    end
    assert_equal 0, @db[:characters].where(account_id: id).count, "the save that landed after the forget is gone too"
    s2 = TCPSocket.new("127.0.0.1", @port)
    send_env(s2, { type: :auth, token: token, resume: true })
    assert_equal "invalid_token", recv_type(s2, :auth_ok, :auth_err)[:reason], "its token went with its sessions"
    s2.close
    s3 = TCPSocket.new("127.0.0.1", @port)
    send_env(s3, { type: :login, email: "gone@t.co", password: "password1" })
    assert_equal "not_found", recv_type(s3, :login_ok, :login_err)[:reason], "its email names nobody"
    s3.close
  end

  # A player who quits before the sweep lets it go: its save queued before it left lands
  # after the console's purge - and is purged again as its socket closes.
  def test_a_player_who_quits_first_is_purged_as_it_leaves
    s, lo = login("quit@t.co")
    id = lo[:account_id]
    hold(id, 2)
    send_env(s, { type: :save, trainer_id: 7 }, "the player's name is in here")
    sleep 0.3
    assert_equal :forgotten, PEMK::Forget.new(@db).forget(id, by: "op")
    s.close                                                               # gone before any sweep
    wait_until("the late save purged", 10) do
      logs.any? { |l| l.match?(/account #{id} forgotten - 1 characters purged after its last work/) }
    end
    assert_equal 0, @db[:characters].where(account_id: id).count
    refute logs.any? { |l| l.include?("is banned - connection closed") }, "no sweep let it go: it left"
  end

  # Any other player's save stays when it quits: the close purges forgotten accounts only.
  def test_a_player_who_quits_keeps_its_save
    s, lo = login("stays@t.co")
    id = lo[:account_id]
    send_env(s, { type: :save, trainer_id: 7 }, "its save")
    wait_until("the save stored", 5) { @db[:characters].where(account_id: id).count == 1 }
    s.close
    sleep 1
    assert_equal 1, @db[:characters].where(account_id: id).count
    refute logs.any? { |l| l.include?("purged") }
  end

  # The badge boot pass plans every account holding a badge: a forgotten one plays no more.
  def test_a_forgotten_account_is_not_planned_at_boot
    _, lo = login("held@t.co")
    _, gone = login("gone2@t.co")
    [lo, gone].each { |l| @db[:economy_balances].insert(account_id: l[:account_id], field: "badges", balance: 1, last_seq: 0) }
    PEMK::Forget.new(@db).forget(gone[:account_id], by: "op")
    assert_equal [lo[:account_id]], @server.send(:badge_boot_accounts, true, nil)
  end
end
