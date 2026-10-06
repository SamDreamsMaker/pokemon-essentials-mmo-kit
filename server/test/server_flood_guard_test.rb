require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# The flood guard, the frame layer: before its login a socket sends what a client sends
# and small frames, or it is closed (each :auth was a pool job and a database read,
# unbounded); logins never delay a player's saves; a logged-in socket that keeps
# flooding is closed and its drops are said once, not once a frame; a type the server
# does not know shares one budget. Off, floods are only dropped, as before.
class ServerFloodGuardTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[monster_transfers monsters enforcement_events].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(extra = {})
    @server = PEMK::Server.new(config: PEMK::Config.new(env: ENV.to_h.merge(extra)), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def logs
    @seen ||= []
    @seen << @logs.pop until @logs.empty?
    @seen
  end

  def frame(env, body = nil) = W.encode_split(env, body)

  def recv(sock, timeout = 2)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)
    end
  end

  # Every frame until the socket closes (-> [frames, :eof]) or stays quiet (-> [frames, :open]).
  def drain(sock, quiet = 0.6)
    got = []
    loop do
      m = recv(sock, quiet)
      return [got, :eof] if m.nil?

      got << m
    end
  rescue Timeout::Error
    [got, :open]
  rescue IOError, SystemCallError
    [got, :eof]
  end

  def open_authed(user, caps: [])
    c = TCPSocket.new("127.0.0.1", @port)
    c.write(frame({ type: :register, email: "#{user}@t.co", password: "password1" }))
    recv(c)
    c.write(frame({ type: :login, email: "#{user}@t.co", password: "password1", caps: caps }))
    [c, recv(c)[:env][:account_id]]
  end

  def on_reactor(&block)
    done = Queue.new
    @server.instance_variable_get(:@reactor).post { done << block.call }
    Timeout.timeout(3) { done.pop }
  end

  # --- before the login -------------------------------------------------------------

  def test_an_auth_flood_before_the_login_is_closed
    start_server
    assert logs.any? { |l| l.start_with?("server: flood guard = on (") }
    s = TCPSocket.new("127.0.0.1", @port)
    s.write(Array.new(4) { |i| frame({ type: :auth, token: "junk#{i}" }) }.join)
    _, state = drain(s, 3)
    assert_equal :eof, state
    assert_equal 1, logs.count { |l| l == "server: pre-auth flood (:auth) from 127.0.0.1 -> closed" }, logs.grep(/pre-auth/).join("\n")
    s2 = TCPSocket.new("127.0.0.1", @port)
    s2.write(Array.new(3) { |i| frame({ type: :auth, token: "junk#{i}" }) }.join)
    got, state = drain(s2)
    assert_equal :open, state, "three is what a client may need"
    assert_equal %w[invalid_token] * 3, got.map { |m| m[:env][:reason] }
    s2.close
  end

  def test_pings_past_the_burst_close_the_socket_and_only_a_number_is_echoed
    start_server
    s = TCPSocket.new("127.0.0.1", @port)
    s.write(Array.new(9) { |i| frame({ type: :ping, t: i }) }.join + frame({ type: :ping, t: "x" * 3000 }))
    got, state = drain(s)
    assert_equal [:open, 10], [state, got.size]
    assert_equal [*0..8, nil], got.map { |m| m[:env][:t] }, "a number, not what the client sent"
    s2 = TCPSocket.new("127.0.0.1", @port)
    s2.write(Array.new(11) { |i| frame({ type: :ping, t: i }) }.join)
    _, state = drain(s2, 3)
    assert_equal :eof, state
    s.close
  end

  # Before its session a socket announces small frames: a login is under 1 KiB.
  def test_a_big_frame_before_the_login_is_closed
    start_server
    s = TCPSocket.new("127.0.0.1", @port)
    s.write([PEMK::Server::PREAUTH_FRAME_MAX + 1].pack("N"))
    _, state = drain(s, 3)
    assert_equal :eof, state
    a, = open_authed("bigsave", caps: %w[save_ack])
    a.write(frame({ type: :save, seq: 1 }, "x" * 100_000))   # after it, a save is no news
    got, = drain(a, 3)
    assert_equal [:save_ok], got.map { |m| m[:env][:type] }
    a.close
  end

  # What the kit's client sends on one socket: a stored token refused, then the configured
  # account (not found), registered, logged in - and a player retyping a password.
  def test_the_clients_own_sequences_pass
    start_server
    s = TCPSocket.new("127.0.0.1", @port)
    s.write(frame({ type: :auth, token: "stale" }))
    assert_equal :auth_err, recv(s)[:env][:type]
    s.write(frame({ type: :login, email: "new@t.co", password: "password1" }))
    assert_equal "not_found", recv(s)[:env][:reason]
    s.write(frame({ type: :register, email: "new@t.co", password: "password1" }))
    assert_equal :register_ok, recv(s)[:env][:type]
    s.write(frame({ type: :login, email: "new@t.co", password: "wrongpass" }))
    assert_equal "bad_password", recv(s)[:env][:reason]
    s.write(frame({ type: :login, email: "new@t.co", password: "password1" }))
    assert_equal :login_ok, recv(s)[:env][:type]
    refute logs.any? { |l| l.match?(/pre-auth flood|floods \(/) }
    s.close
  end

  def test_off_a_flood_before_the_login_is_answered
    start_server({ "PEMK_FLOOD_GUARD" => "off" })
    assert logs.any? { |l| l == "server: flood guard = off (floods are only dropped)" }
    s = TCPSocket.new("127.0.0.1", @port)
    s.write(Array.new(10) { |i| frame({ type: :auth, token: "junk#{i}" }) }.join)
    got, state = drain(s)
    assert_equal [:open, 10], [state, got.size]
    s.close
  end

  # A login already made spends none of the address's attempts.
  def test_a_second_login_on_a_socket_spends_no_attempt
    start_server
    a, = open_authed("twice")
    12.times { a.write(frame({ type: :login, email: "twice@t.co", password: "password1" })) }
    got, = drain(a)
    assert_equal ["already_authed"] * 12, got.map { |m| m[:env][:reason] }
    b = TCPSocket.new("127.0.0.1", @port)
    b.write(frame({ type: :login, email: "twice@t.co", password: "password1" }))
    assert_equal :login_ok, recv(b)[:env][:type], "the address still has its attempts"
    [a, b].each(&:close)
  end

  # A storm of logins (a bcrypt each, slowed here) runs beside the players' work: a save
  # is answered while every login waits.
  def test_logins_never_delay_a_save
    start_server
    p1, = open_authed("player", caps: %w[save_ack])
    accounts = @server.instance_variable_get(:@accounts)
    accounts.define_singleton_method(:authenticate) { |*| sleep 1.5; [nil, :not_found] }
    socks = Array.new(8) { TCPSocket.new("127.0.0.1", @port) }
    socks.each { |s| s.write(frame({ type: :login, email: "x@t.co", password: "password1" })) }
    sleep 0.2
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    p1.write(frame({ type: :save, seq: 1 }, "blob"))
    got, = drain(p1, 1.2)
    assert_equal [:save_ok], got.map { |m| m[:env][:type] }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 1.4, "answered before the logins"
    (socks + [p1]).each(&:close)
  end

  # --- after it ---------------------------------------------------------------------

  def test_a_flood_after_the_login_is_closed_and_said_once
    start_server
    s, id = open_authed("flood")
    s.write(Array.new(1100) { |i| frame({ type: :pos, map: 1, x: i % 2, y: 0, dir: 2 }) }.join)
    _, state = drain(s, 5)
    assert_equal :eof, state
    assert_equal 1, logs.count { |l| l.start_with?("server: account #{id} floods (") }
    assert_equal 1, logs.count { |l| l.start_with?("server: account #{id} over budget on :pos -> drop") },
                 "said once, not once a frame"
  end

  def test_off_a_flood_after_the_login_is_only_dropped
    start_server({ "PEMK_FLOOD_GUARD" => "off" })
    s, id = open_authed("dropped")
    s.write(Array.new(1100) { |i| frame({ type: :pos, map: 1, x: i % 2, y: 0, dir: 2 }) }.join)
    sleep 1
    s.write(frame({ type: :ping, t: 1 }))
    got, state = drain(s)
    assert_equal :open, state
    assert_equal [:pong], got.map { |m| m[:env][:type] }
    assert_equal 1, logs.count { |l| l.start_with?("server: account #{id} over budget on :pos -> drop (1 dropped)") }
    refute logs.any? { |l| l.include?("account #{id} floods") }
  end

  # A player's client declines invites by itself: a storm of invites makes it answer past
  # its budget, and those answers must not close it.
  def test_handshake_answers_are_never_a_flood
    start_server
    a, a_id = open_authed("decliner")
    b, = open_authed("inviter")
    a.write(Array.new(1100) { frame({ type: :trade_decline, to: 999_999, trade_id: "t" }) }.join)
    sleep 1
    a.write(frame({ type: :ping, t: 1 }))
    got, state = drain(a)
    assert_equal :open, state
    assert_equal [:pong], got.map { |m| m[:env][:type] }
    refute logs.any? { |l| l.include?("account #{a_id} floods") }
    [a, b].each(&:close)
  end

  # The client names the type: any this server does not know shares one budget from the
  # first (a budget each was a fresh burst, and memory for the connection's life), and
  # the line it wrote each frame - as large as the frame - is said once.
  def test_unknown_types_share_a_budget_and_one_line
    start_server
    s, id = open_authed("names")
    s.write(Array.new(200) { |i| frame({ type: :"zz#{i}" }) }.join)
    sleep 0.5
    keys = on_reactor { @server.instance_variable_get(:@online)[id].data[:budgets].keys }
    assert_equal %i[other], keys - %i[login register auth ping]
    assert_equal 1, logs.count { |l| l.include?("a frame this server does not know") }
    assert_equal 1, logs.count { |l| l.include?("over budget on :other") }
    s.close
  end

  # Every type a handler reads has its own budget: a new handler must be listed.
  def test_every_handled_type_is_known
    src = File.read(File.expand_path("../lib/pemk/server.rb", __dir__))
    dispatch = src[/def dispatch_frame.*?\n    end\n/m]
    handled = dispatch.scan(/when ((?::\w+(?:, )?)+) then/).flat_map { |(list)| list.scan(/:(\w+)/).flatten.map(&:to_sym) }
    refute_empty handled
    assert_empty handled - PEMK::Server::KNOWN_TYPES
  end

  # An IPv6 host holds a whole /64: the login limiter counts it as one address.
  def test_the_limiter_counts_an_ipv6_host_by_its_64
    srv = PEMK::Server.allocate
    assert_equal "2001:db8:1:2::", srv.send(:limiter_key, "2001:db8:1:2:aaaa:bbbb:cccc:dddd")
    assert_equal srv.send(:limiter_key, "2001:db8:1:2::1"), srv.send(:limiter_key, "2001:db8:1:2:ffff::9")
    refute_equal srv.send(:limiter_key, "2001:db8:1:2::1"), srv.send(:limiter_key, "2001:db8:1:3::1")
    assert_equal "203.0.113.7", srv.send(:limiter_key, "::ffff:203.0.113.7")
    assert_equal "203.0.113.7", srv.send(:limiter_key, "203.0.113.7")
    assert_equal "?", srv.send(:limiter_key, "?")
  end
end
