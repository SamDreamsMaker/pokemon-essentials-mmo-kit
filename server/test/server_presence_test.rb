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

# Zone-scoped presence: same-map players see each other's position (stamped with
# the server-trusted account id, not a client-claimed id); different maps stay
# isolated; a disconnect fans a :leave to same-map peers.
class ServerPresenceTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @server = PEMK::Server.new(logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def send_env(sock, env)
    sock.write(W.encode_split(env))
  end

  def recv_env(sock, timeout = 2)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def refute_receives(sock, timeout = 0.5)
    assert_raises(Timeout::Error) { recv_env(sock, timeout) }
  end

  # +caps+: what the client says it can do (presence_v2: it keeps peers until a leave).
  def open_authed(user, pw, caps: nil)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, email: "#{user}@t.co", password: pw })
    recv_env(c)
    login = { type: :login, email: "#{user}@t.co", password: pw }
    login[:caps] = caps if caps
    send_env(c, login)
    [c, recv_env(c)[:account_id]]
  end

  # The frames coming to +sock+ -> [env, ...]: the first within +first+ seconds (a
  # loaded host is slow), the next ones until +quiet+ seconds pass with none. A check
  # that expects nothing passes a short +first+.
  def drain(sock, quiet = 0.3, first: 2.0)
    out = []
    loop { out << recv_env(sock, out.empty? ? first : quiet) }
  rescue Timeout::Error
    out
  end

  def nothing(sock)
    drain(sock, first: 0.6)
  end

  # login_ok's :presence_v2 for a new account logging in with +caps+
  def login_flag(user, caps)
    probe = TCPSocket.new("127.0.0.1", @port)
    send_env(probe, { type: :register, email: "#{user}@t.co", password: "password1" })
    recv_env(probe)
    login = { type: :login, email: "#{user}@t.co", password: "password1" }
    login[:caps] = caps if caps
    send_env(probe, login)
    recv_env(probe)[:presence_v2]
  ensure
    probe&.close
  end

  def on_reactor(&block)
    done = Queue.new
    @server.instance_variable_get(:@reactor).post { done << block.call }
    Timeout.timeout(3) { done.pop }
  end

  def test_same_map_players_see_each_other_with_server_identity
    a, a_id = open_authed("Alice", "passwordA1")
    b, b_id = open_authed("Bobby", "passwordB1")

    send_env(a, { type: :pos, map: 5, x: 1, y: 1, id: 999_999 }) # a alone; spoofed id ignored
    send_env(b, { type: :pos, map: 5, x: 2, y: 2 })              # -> a hears b

    from_b = recv_env(a)
    assert_equal :pos, from_b[:type]
    assert_equal b_id, from_b[:id]
    assert_equal 5, from_b[:map]
    already = recv_env(b)                                         # b entering: who is there
    assert_equal [a_id, 1], already.values_at(:id, :x)

    send_env(a, { type: :pos, map: 5, x: 3, y: 3 })              # -> b hears a
    from_a = recv_env(b)
    assert_equal a_id, from_a[:id]
    assert_equal 3, from_a[:x]

    a.close
    b.close
  end

  # Presence v2: an idle repeat reaches only the older clients (their timeout needs
  # it); a move reaches everyone.
  def test_an_idle_repeat_reaches_only_older_clients
    assert_equal true, login_flag("Aflag", %w[presence_v2]), "login says idle repeats are kept from it"
    assert_equal false, login_flag("Bflag", nil), "not to a client that cannot keep its peers"
    a, a_id = open_authed("Av2", "passwordA1", caps: %w[presence_v2])
    b, = open_authed("Bv2", "passwordB1", caps: %w[presence_v2])
    c, = open_authed("Cold", "passwordC1")
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 5, x: 2, y: 2 })
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })
    [a, b, c].each { |s| nothing(s) }

    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })   # the heartbeat of a player standing still
    assert_equal [[a_id, 1]], drain(c).map { |e| e.values_at(:id, :x) }, "the older client still hears it"
    assert_empty nothing(b), "a v2 client does not"
    send_env(a, { type: :step, map: 5, x: 1, y: 2 })
    assert_equal [a_id], drain(b).map { |e| e[:id] }
    assert_equal [a_id], drain(c).map { |e| e[:id] }
    [a, b, c].each(&:close)
  end

  # A player entering a map is sent everyone already there - and so is one asking (:sync).
  def test_a_player_entering_a_map_sees_everyone_there
    a, a_id = open_authed("Aent", "passwordA1", caps: %w[presence_v2])
    b, b_id = open_authed("Bent", "passwordB1", caps: %w[presence_v2])
    send_env(a, { type: :pos, map: 6, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 6, x: 2, y: 2 })
    [a, b].each { |s| nothing(s) }
    d, d_id = open_authed("Dent", "passwordD1", caps: %w[presence_v2])
    send_env(d, { type: :pos, map: 6, x: 4, y: 4 })
    assert_equal [a_id, b_id].sort, drain(d).map { |e| e[:id] }.sort, "everyone already on the map"
    assert_equal [d_id], drain(a).map { |e| e[:id] }
    send_env(a, { type: :pos, map: 6, x: 1, y: 1, sync: true })   # its remotes were cleared
    assert_equal [b_id, d_id].sort, drain(a).map { |e| e[:id] }.sort
    [a, b, d].each(&:close)
  end

  # A member silent for PRESENCE_SILENCE leaves its map (a dead link the socket has not
  # shown yet); its next frame brings it back, with who is there.
  def test_a_silent_member_leaves_its_map
    a, a_id = open_authed("Asil", "passwordA1", caps: %w[presence_v2])
    b, b_id = open_authed("Bsil", "passwordB1", caps: %w[presence_v2])
    send_env(a, { type: :pos, map: 7, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 7, x: 2, y: 2 })
    [a, b].each { |s| nothing(s) }
    on_reactor do                                    # the reactor's own tick sweeps it
      conn = @server.instance_variable_get(:@online)[a_id]
      conn.data[:presence_seen] -= PEMK::Server::PRESENCE_SILENCE + 1
      @server.instance_variable_set(:@presence_swept_at, nil)
    end
    assert_equal [[:leave, a_id]], drain(b).map { |e| e.values_at(:type, :id) }
    assert_equal [[:leave, b_id]], drain(a).map { |e| e.values_at(:type, :id) },
                 "it drops everyone too: out of the zone, it would hear no leave"
    assert_equal 7, on_reactor { @server.instance_variable_get(:@online)[a_id].data[:map_id] },
                 "its last map stays known (claims, the reconnect fallback)"
    send_env(a, { type: :pos, map: 7, x: 1, y: 1 })
    assert_equal [b_id], drain(a).map { |e| e[:id] }, "back on its map: who is there"
    assert_equal [a_id], drain(b).map { |e| e[:id] }
    [a, b].each(&:close)
  end

  # A snapshot that overflows its joiner's output closes it: its frame must go out
  # before the leave that close sends, or every peer keeps a ghost.
  def test_a_snapshot_that_closes_its_joiner_leaves_no_ghost
    a, a_id = open_authed("Aghost", "passwordA1", caps: %w[presence_v2])
    b, = open_authed("Bghost", "passwordB1", caps: %w[presence_v2])
    send_env(b, { type: :pos, map: 4, x: 2, y: 2 })
    nothing(b)
    reactor = @server.instance_variable_get(:@reactor)
    @server.define_singleton_method(:send_snapshot) { |c, _map| reactor.send(:close_conn, c) }   # it overflows
    send_env(a, { type: :pos, map: 4, x: 1, y: 1 })
    assert_equal [[:pos, a_id], [:leave, a_id]], drain(b).map { |e| e.values_at(:type, :id) }
    [a, b].each(&:close)
  end

  # A socket logging in again as another account leaves its map under the first one.
  def test_a_socket_logging_in_again_leaves_its_map
    a, a_id = open_authed("Aagain", "passwordA1", caps: %w[presence_v2])
    b, = open_authed("Bagain", "passwordB1", caps: %w[presence_v2])
    send_env(a, { type: :pos, map: 3, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 3, x: 2, y: 2 })
    [a, b].each { |s| nothing(s) }
    send_env(a, { type: :register, email: "Yagain@t.co", password: "passwordY1" })
    recv_env(a)
    send_env(a, { type: :login, email: "Yagain@t.co", password: "passwordY1", caps: %w[presence_v2] })
    assert_equal :login_ok, recv_env(a)[:type]
    assert_equal [[:leave, a_id]], drain(b).map { |e| e.values_at(:type, :id) }
    [a, b].each(&:close)
  end

  # A :sync is honoured at most every SYNC_EVERY: each is a frame per peer.
  def test_a_sync_is_honoured_once_every_few_seconds
    a, = open_authed("Async", "passwordA1", caps: %w[presence_v2])
    b, b_id = open_authed("Bsync", "passwordB1", caps: %w[presence_v2])
    send_env(a, { type: :pos, map: 2, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 2, x: 2, y: 2 })
    [a, b].each { |s| nothing(s) }
    send_env(a, { type: :pos, map: 2, x: 1, y: 1, sync: true })
    assert_equal [b_id], drain(a).map { |e| e[:id] }
    send_env(a, { type: :pos, map: 2, x: 1, y: 1, sync: true })
    assert_empty nothing(a), "a second ask within a few seconds gets no second snapshot"
    [a, b].each(&:close)
  end

  # A session replaced by a newer login leaves its map at once - not when its socket
  # finally closes: over a dead link that can take a while, and its late leave would
  # hide the new session from its peers.
  def test_a_replaced_session_leaves_at_once
    a, a_id = open_authed("Arep", "passwordA1", caps: %w[presence_v2])
    a.close                                          # registered; this socket goes
    b, = open_authed("Brep", "passwordB1", caps: %w[presence_v2])
    send_env(b, { type: :pos, map: 8, x: 2, y: 2 })
    nothing(b)
    dead = on_reactor do                             # the account on map 8 over a link that never drains
      c = PEMK::Reactor::Conn.new(Object.new, "dead")
      c.data.merge!(account_id: a_id, presence_v2: true, map_id: 8,
                    presence_seen: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      @server.instance_variable_get(:@online)[a_id] = c
      @server.send(:zone_join, c, 8)
      c
    end
    a2 = TCPSocket.new("127.0.0.1", @port)
    send_env(a2, { type: :login, email: "Arep@t.co", password: "passwordA1", caps: %w[presence_v2] })
    assert_equal :login_ok, recv_env(a2)[:type]
    assert_equal [[:leave, a_id]], drain(b).map { |e| e.values_at(:type, :id) }, "at once, the old link still open"
    assert_equal 8, on_reactor { dead.data[:map_id] }, "its last map stays known for the reconnect fallback"
    send_env(a2, { type: :pos, map: 8, x: 1, y: 1 })
    assert_equal [[:pos, a_id]], drain(b).map { |e| e.values_at(:type, :id) }
    on_reactor { @server.send(:on_close, dead) }   # the dead link finally goes
    assert_empty nothing(b), "no late leave hides the new session"
    [a2, b].each(&:close)
  end

  # Presence frames share one budget: alternating types does not multiply the fan-out.
  def test_presence_frames_share_one_budget
    a, = open_authed("Abud", "passwordA1", caps: %w[presence_v2])
    b, = open_authed("Bbud", "passwordB1", caps: %w[presence_v2])
    send_env(b, { type: :pos, map: 9, x: 0, y: 0 })
    send_env(a, { type: :pos, map: 9, x: 0, y: 0 })
    [a, b].each { |s| nothing(s) }
    types = %i[pos dir step]
    a.write((1..120).map { |i| W.encode_split({ type: types[i % 3], map: 9, x: i, y: 0, dir: 2 + (2 * (i % 4)) }) }.join)
    got = drain(b, 0.5).size
    assert_operator got, :<=, 60, "one 40-frame burst, not three"
    assert_operator got, :>=, 30
    [a, b].each(&:close)
  end

  # Peers draw a player from its sprite, pace and name: those pass; anything else
  # the client attaches does not (the fan-out is not an amplifier).
  def test_presence_carries_what_peers_draw_and_nothing_else
    a, = open_authed("Adraw", "passwordA1")
    b, = open_authed("Bdraw", "passwordB1")
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 5, x: 2, y: 2, dir: 4, speed: 4, mode: :walk,
                  char: "trainer_POKEMONTRAINER_Red", name: "Bob", junk: "x" * 1000 })

    got = recv_env(a)
    assert_equal "Bob", got[:name]
    assert_equal "trainer_POKEMONTRAINER_Red", got[:char]
    assert_equal 4, got[:speed]
    assert_equal :walk, got[:mode]
    refute got.key?(:junk)
    a.close
    b.close
  end

  # Every peer on the map shows these: the name loses its message codes, a path is
  # no sprite, and an impossible pace is dropped.
  def test_presence_fields_are_checked
    a, = open_authed("Acheck", "passwordA1")
    b, = open_authed("Bcheck", "passwordB1")
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 5, x: 2, y: 2, speed: 99, char: "../../Titles/title",
                  name: "\\ch[51,0,Yes]Eve<b>" })

    got = recv_env(a)
    assert_equal "ch[51,0,Yes]Eveb", got[:name]
    refute got.key?(:char)
    refute got.key?(:speed)
    a.close
    b.close
  end

  def test_different_maps_do_not_cross
    a, = open_authed("Amap", "passwordA1")
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })

    c, = open_authed("Cmap", "passwordC1")
    send_env(c, { type: :pos, map: 9, x: 1, y: 1 })

    refute_receives(a) # map 5 hears nothing from map 9
    a.close
    c.close
  end

  def test_disconnect_broadcasts_leave
    a, = open_authed("Ayla", "passwordA1")
    b, b_id = open_authed("Bill", "passwordB1")
    send_env(a, { type: :pos, map: 7, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 7, x: 2, y: 2 })
    recv_env(a) # drain b's pos

    b.close
    left = recv_env(a)
    assert_equal :leave, left[:type]
    assert_equal b_id, left[:id]
    a.close
  end

  # PEMK_PRESENCE_DEDUP=off: every frame to everyone, no snapshot - as before.
  def test_the_kill_switch_sends_every_frame
    @server.stop
    env = ENV.to_h.merge("PEMK_PRESENCE_DEDUP" => "off")
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(_m) {})
    @server.start
    @port = @server.port
    probe = TCPSocket.new("127.0.0.1", @port)
    send_env(probe, { type: :register, email: "Kflag@t.co", password: "passwordA1" })
    recv_env(probe)
    send_env(probe, { type: :login, email: "Kflag@t.co", password: "passwordA1" })
    assert_equal false, recv_env(probe)[:presence_v2]
    probe.close
    a, a_id = open_authed("Akill", "passwordA1", caps: %w[presence_v2])
    b, = open_authed("Bkill", "passwordB1", caps: %w[presence_v2])
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 5, x: 2, y: 2 })
    assert_empty nothing(b), "no snapshot"
    drain(a)
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })
    assert_equal [a_id], drain(b).map { |e| e[:id] }, "an idle repeat reaches everyone"
    [a, b].each(&:close)
  end
end
