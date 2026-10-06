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

# The relay guard: a session is per pair and kind, an invite is answered only by whom it
# invited, a teardown ends its own pair's session only - so nobody breaks another
# player's battle or trade, and an honest invite to a player in a battle no longer does
# (its client's automatic decline cleared that battle's session); a handshake carries an
# invite and no more; a partner's bodies keep the kit's sizes; a player gone mid-battle
# ends it for the other. Off, the relay is as before.
class ServerRelayGuardTest < Minitest::Test
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
  def send_env(s, env, body = nil) = s.write(frame(env, body))

  def recv(sock, timeout = 2)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)
    end
  end

  def drain(sock, quiet = 0.5)
    got = []
    loop do
      m = recv(sock, quiet)
      return got if m.nil?

      got << m
    end
  rescue Timeout::Error, IOError, SystemCallError
    got
  end

  def types(sock) = drain(sock).map { |m| m[:env][:type] }

  def login(user)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, email: "#{user}@t.co", password: "password1" })
    recv(c)
    send_env(c, { type: :login, email: "#{user}@t.co", password: "password1" })
    id = recv(c)[:env][:account_id]
    (@ids ||= {})[c] = id
    [c, id]
  end

  def battle(a, a_id, b, b_id)
    send_env(a, { type: :challenge, to: b_id, name: "A" })
    assert_equal :challenge, recv(b)[:env][:type]
    send_env(b, { type: :challenge_accept, to: a_id, name: "B" })
    assert_equal :challenge_accept, recv(a)[:env][:type]
  end

  def trade(a, a_id, b, b_id, tid)
    send_env(a, { type: :trade_invite, to: b_id, trade_id: tid, name: "A" })
    assert_equal :trade_invite, recv(b)[:env][:type]
    send_env(b, { type: :trade_accept, to: a_id, trade_id: tid, name: "B" })
    assert_equal :trade_accept, recv(a)[:env][:type]
  end

  # THE honest break: B battles C; A invites B to trade; B's client, busy, declines by
  # itself; A gives up and cancels. The battle's session used to go with that decline.
  def test_an_invite_to_a_player_in_a_battle_breaks_nothing
    start_server
    a, a_id = login("a1")
    b, b_id = login("b1")
    c, c_id = login("c1")
    battle(c, c_id, b, b_id)
    send_env(a, { type: :trade_invite, to: b_id, trade_id: "t1", name: "A" })
    assert_equal [:trade_invite], types(b)
    send_env(b, { type: :trade_decline, to: a_id, trade_id: "t1" })
    assert_equal [:trade_decline], types(a)
    send_env(a, { type: :trade_cancel, to: b_id, trade_id: "t1" })
    send_env(c, { type: :battle_choice, to: b_id, round: 1, idxBattler: 1, cmd: [0, 0] })
    assert_equal [:battle_choice], types(b), "the battle's frames still flow"
    [a, b, c].each(&:close)
  end

  # A stranger: its accept opens nothing, its team reaches no one, its cancel ends nothing.
  def test_a_strangers_answers_and_teardowns_reach_no_one
    start_server
    a, a_id = login("a2")
    b, b_id = login("b2")
    s, = login("stranger")
    battle(a, a_id, b, b_id)
    send_env(s, { type: :challenge_accept, to: b_id })
    send_env(s, { type: :battle_team, to: b_id }, Marshal.dump([1]))
    send_env(s, { type: :trade_cancel, to: b_id, trade_id: "x" })
    send_env(s, { type: :battle_end, to: b_id, decision: 1 })
    assert_empty types(b)
    send_env(a, { type: :battle_round, to: b_id, round: 1, rng: [1, 2] })
    assert_equal [:battle_round], types(b), "the real partner's frames still flow"
    assert logs.any? { |l| l.match?(/account \d+ :challenge_accept with no invite of #{b_id} to answer -> drop/) }
    [a, b, s].each(&:close)
  end

  # A player battles one and trades with another: two sessions, each frame in its own.
  def test_a_battle_and_a_trade_at_once
    start_server
    a, a_id = login("a3")
    b, b_id = login("b3")
    c, c_id = login("c3")
    battle(c, c_id, b, b_id)
    trade(a, a_id, b, b_id, "t3")
    send_env(c, { type: :battle_choice, to: b_id, round: 1 })
    send_env(a, { type: :trade_offer, to: b_id, trade_id: "t3", uid: 5 })
    assert_equal %i[battle_choice trade_offer], types(b).sort
    send_env(a, { type: :battle_choice, to: b_id, round: 1 })                 # no battle between a and b
    send_env(c, { type: :trade_offer, to: b_id, trade_id: "t3", uid: 6 })     # no trade between c and b
    send_env(a, { type: :trade_offer, to: b_id, trade_id: "other", uid: 7 })  # another trade
    assert_empty types(b)
    [a, b, c].each(&:close)
  end

  # Both invites from one player: the trade declined, the challenge accepted.
  def test_a_trade_invite_and_a_challenge_from_one_player
    start_server
    a, a_id = login("a4")
    b, b_id = login("b4")
    send_env(a, { type: :trade_invite, to: b_id, trade_id: "t4" })
    send_env(a, { type: :challenge, to: b_id })
    assert_equal %i[trade_invite challenge], types(b)
    send_env(b, { type: :trade_decline, to: a_id, trade_id: "t4" })
    send_env(b, { type: :challenge_accept, to: a_id })
    assert_equal %i[trade_decline challenge_accept], types(a)
    send_env(a, { type: :battle_team, to: b_id }, Marshal.dump([1]))
    assert_equal [:battle_team], types(b), "the battle opened"
    [a, b].each(&:close)
  end

  def test_an_answer_needs_its_invite
    start_server
    a, a_id = login("a5")
    b, b_id = login("b5")
    send_env(b, { type: :challenge_accept, to: a_id })                       # no invite
    send_env(a, { type: :trade_invite, to: b_id, trade_id: "t5" })
    assert_equal [:trade_invite], types(b)
    send_env(b, { type: :challenge_accept, to: a_id })                       # the other kind
    send_env(b, { type: :trade_accept, to: a_id, trade_id: "nope" })         # another trade
    send_env(a, { type: :trade_accept, to: b_id, trade_id: "t5" })           # the inviter itself
    assert_empty types(a)
    assert_empty types(b)
    send_env(b, { type: :trade_accept, to: a_id, trade_id: "t5" })
    assert_equal [:trade_accept], types(a)
    send_env(b, { type: :trade_accept, to: a_id, trade_id: "t5" })           # answered already
    assert_empty types(a)
    [a, b].each(&:close)
  end

  # The inviter's watchdog cancels before any answer: relayed (the invitee is told at once).
  def test_the_inviters_cancel_before_an_answer_reaches_the_invitee
    start_server
    a, = login("a6")
    b, b_id = login("b6")
    send_env(a, { type: :trade_invite, to: b_id, trade_id: "t6" })
    send_env(a, { type: :trade_cancel, to: b_id, trade_id: "t6" })
    assert_equal %i[trade_invite trade_cancel], types(b)
    send_env(a, { type: :trade_cancel, to: b_id, trade_id: "t6" })           # nothing left to end
    assert_empty types(b)
    [a, b].each(&:close)
  end

  # A side that committed cannot cancel (its partner, committing too, would drop the trade
  # and miss its result); once both commit, the trade's session is over; a new one opens.
  def test_a_committed_trade_is_the_servers
    start_server
    a, a_id = login("a7")
    b, b_id = login("b7")
    trade(a, a_id, b, b_id, "t7")
    send_env(a, { type: :trade_commit, trade_id: "t7", partner: b_id, give: [11], recv: [22] })
    sleep 0.2
    send_env(a, { type: :trade_cancel, to: b_id, trade_id: "t7" })
    assert_empty types(b), "a cancel after its own commit"
    assert logs.any? { |l| l.include?(":trade_cancel after its own commit -> drop") }
    send_env(b, { type: :trade_commit, trade_id: "t7", partner: a_id, give: [22], recv: [11] })
    assert_includes types(a), :trade_result
    drain(b)
    send_env(a, { type: :trade_offer, to: b_id, trade_id: "t7", uid: 11 })
    assert_empty types(b), "the trade is over"
    trade(a, a_id, b, b_id, "t7b")
    [a, b].each(&:close)
  end

  # The host's battle end closes the battle: no frame of it passes after, and nothing is
  # sent for it when a player leaves.
  def test_a_battle_end_closes_the_battle
    start_server
    a, a_id = login("a14")
    b, b_id = login("b14")
    battle(a, a_id, b, b_id)
    send_env(a, { type: :battle_end, to: b_id, decision: 1 })
    assert_equal [:battle_end], types(b)
    send_env(a, { type: :battle_choice, to: b_id, round: 9 })
    assert_empty types(b), "the battle is over"
    a.close
    assert_empty types(b), "nothing to end for it"
    b.close
  end

  # A player gone mid-battle: its partner's battle ends (a draw) instead of waiting for
  # good; a trade partner is told the trade is off.
  def test_a_player_gone_ends_its_battle_and_its_trade
    start_server
    a, a_id = login("a8")
    b, b_id = login("b8")
    c, c_id = login("c8")
    battle(a, a_id, b, b_id)
    trade(a, a_id, c, c_id, "t8")
    a.close
    got = drain(b, 1.5).map { |m| m[:env] }
    assert_equal [[:battle_end, a_id, 5]], got.map { |e| e.values_at(:type, :from, :decision) }
    got = drain(c, 1.5).map { |m| m[:env] }
    assert_equal [[:trade_cancel, a_id, "t8"]], got.map { |e| e.values_at(:type, :from, :trade_id) }
    [b, c].each(&:close)
  end

  def test_a_handshake_carries_an_invite_only
    start_server
    a, = login("a9")
    b, b_id = login("b9")
    send_env(a, { type: :challenge, to: b_id, name: "Ann" }, "a body")
    m = recv(b)
    assert_equal [:challenge, nil], [m[:env][:type], m[:body]], "relayed, its body not"
    send_env(a, { type: :trade_invite, to: b_id, trade_id: "t9", pad: "x" * 3000 })
    assert_empty types(b)
    assert logs.any? { |l| l.match?(/:trade_invite of \d+B - an invite is small -> drop/) }
    [a, b].each(&:close)
  end

  # Five invites, then one per 5 s - per account: a new socket refills nothing.
  def test_invites_are_rationed_per_account
    start_server
    a, = login("a10")
    b, b_id = login("b10")
    send_env(a, { type: :challenge, to: b_id }) && 5.times { |i| send_env(a, { type: :trade_invite, to: b_id, trade_id: "t#{i}" }) }
    assert_equal 5, types(b).size
    a.close
    a2 = TCPSocket.new("127.0.0.1", @port)
    send_env(a2, { type: :login, email: "a10@t.co", password: "password1" })
    recv(a2)
    send_env(a2, { type: :challenge, to: b_id })
    assert_empty types(b), "the new socket has the account's invites"
    [a2, b].each(&:close)
  end

  # Whose output is far behind gets no invite: a handshake must not grow it further. (Its
  # socket takes little and is never read: what the server sends it piles up.)
  def test_a_player_far_behind_gets_no_invite
    start_server
    a, = login("a11")
    b = Socket.new(:INET, :STREAM)
    b.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
    b.connect(Socket.sockaddr_in(@port, "127.0.0.1"))
    send_env(b, { type: :register, email: "b11@t.co", password: "password1" })
    recv(b)
    send_env(b, { type: :login, email: "b11@t.co", password: "password1" })
    b_id = recv(b)[:env][:account_id]
    online = @server.instance_variable_get(:@online)
    reactor = @server.instance_variable_get(:@reactor)
    queued = Queue.new
    reactor.post do
      online[b_id].io.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)   # the kernel takes little
      55.times { reactor.send_frame(online[b_id], W.encode_split({ type: :pad }, "\0".b * (64 * 1024))) }
      queued << online[b_id].outbuf.bytesize
    end
    assert_operator Timeout.timeout(3) { queued.pop }, :>, PEMK::Server::HANDSHAKE_OUTBUF_MAX, "behind"
    send_env(a, { type: :challenge, to: b_id })
    sleep 0.3
    assert logs.any? { |l| l.match?(/:challenge to #{b_id}, whose output is \d+ KiB behind -> drop/) }, logs.grep(/behind/).join("\n")
    [a, b].each(&:close)
  end

  # A partner sends bodies as the kit does: a team (<= 64 KiB) and an escrow, a few.
  def test_a_partners_bodies_keep_the_kits_sizes
    start_server
    a, a_id = login("a12")
    b, b_id = login("b12")
    battle(a, a_id, b, b_id)
    send_env(a, { type: :battle_team, to: b_id }, "x" * (70 * 1024))
    assert_empty types(b)
    send_env(a, { type: :battle_choice, to: b_id, round: 1 }, "no body here")
    m = recv(b)
    assert_equal [:battle_choice, nil], [m[:env][:type], m[:body]]
    5.times { send_env(a, { type: :battle_team, to: b_id }, "team") }
    assert_equal 4, types(b).size, "four, then one per 10 s"
    [a, b].each(&:close)
  end

  # A stranger's decline reaches no one: the client's own check of a decline is that it
  # is addressed to it, so it would forget its challenge and say "X declined".
  def test_a_strangers_decline_reaches_no_one
    start_server
    a, = login("a15")
    b, b_id = login("b15")
    s, = login("s15")
    send_env(b, { type: :challenge, to: a_id_of(a) })
    drain(a)
    send_env(s, { type: :challenge_decline, to: b_id })
    send_env(s, { type: :trade_decline, to: b_id, trade_id: "t" })
    assert_empty types(b)
    [a, b, s].each(&:close)
  end

  # A cancelled trade is closed: no frame of it passes, and a commit after it - a
  # modified client's, its partner having dropped the trade - is refused, the partner's
  # waiting commit with it.
  def test_a_cancelled_trade_cannot_be_committed
    start_server
    a, a_id = login("a16")
    b, b_id = login("b16")
    trade(a, a_id, b, b_id, "t16")
    send_env(b, { type: :trade_commit, trade_id: "t16", partner: a_id, give: [2], recv: [1] })
    sleep 0.2
    send_env(a, { type: :trade_cancel, to: b_id, trade_id: "t16" })
    assert_equal [:trade_cancel], types(b)
    send_env(a, { type: :trade_offer, to: b_id, trade_id: "t16", uid: 1 })
    assert_empty types(b)
    send_env(a, { type: :trade_commit, trade_id: "t16", partner: b_id, give: [1], recv: [2] })
    assert_equal [%i[trade_result no_trade]], drain(a).map { |m| [m[:env][:type], m[:env][:reason]&.to_sym] }
    assert_equal [%i[trade_result no_trade]], drain(b).map { |m| [m[:env][:type], m[:env][:reason]&.to_sym] }
    [a, b].each(&:close)
  end

  # Who committed waits for its partner: told "partner_left" when the partner goes, never a
  # cancel; a partner who had not committed is told the trade is off.
  def test_a_partner_gone_after_a_commit
    start_server
    a, a_id = login("a17")
    b, b_id = login("b17")
    trade(a, a_id, b, b_id, "t17")
    send_env(b, { type: :trade_commit, trade_id: "t17", partner: a_id, give: [2], recv: [1] })
    sleep 0.2
    a.close
    got = drain(b, 1.5).map { |m| m[:env] }
    assert_equal [[:trade_result, "partner_left"]], got.map { |e| [e[:type], e[:reason]] }
    c, c_id = login("c17")
    d, d_id = login("d17")
    trade(c, c_id, d, d_id, "t17b")
    send_env(c, { type: :trade_commit, trade_id: "t17b", partner: d_id, give: [3], recv: [4] })
    sleep 0.2
    c.close
    got = drain(d, 1.5).map { |m| m[:env] }
    assert_equal [[:trade_cancel, "t17b"]], got.map { |e| [e[:type], e[:trade_id]] }
    [b, d].each(&:close)
  end

  # A relogin replaces the socket: its battles end for the partner at once, even while the
  # old socket still holds unsent output (it closes late: the partner was never told).
  def test_a_relogin_ends_the_battle_for_the_partner
    start_server
    a, a_id = login("a18")
    b, b_id = login("b18")
    battle(a, a_id, b, b_id)
    online = @server.instance_variable_get(:@online)
    reactor = @server.instance_variable_get(:@reactor)
    stuck = Queue.new
    reactor.post do
      online[a_id].io.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)   # the old link takes little
      55.times { reactor.send_frame(online[a_id], W.encode_split({ type: :pad }, "\0".b * (64 * 1024))) }
      stuck << online[a_id].outbuf.bytesize
    end
    assert_operator Timeout.timeout(3) { stuck.pop }, :>, 0, "the old socket cannot drain"
    a2 = TCPSocket.new("127.0.0.1", @port)
    send_env(a2, { type: :login, email: "a18@t.co", password: "password1" })
    recv(a2)
    got = drain(b, 1.5).map { |m| m[:env] }
    assert_equal [[:battle_end, a_id, 5]], got.map { |e| e.values_at(:type, :from, :decision) }
    [a, a2, b].each(&:close)
  end

  # A trade frame names its trade by a String, as the kit does: none, or a number, could
  # stand for another trade of the pair.
  def test_a_trade_frame_needs_a_trade_id
    start_server
    a, a_id = login("a20")
    b, b_id = login("b20")
    send_env(a, { type: :trade_invite, to: b_id })
    send_env(a, { type: :trade_invite, to: b_id, trade_id: 1 })
    assert_empty types(b)
    send_env(a, { type: :trade_invite, to: b_id, trade_id: "t20" })
    assert_equal [:trade_invite], types(b)
    send_env(b, { type: :trade_accept, to: a_id })
    assert_empty types(a)
    [a, b].each(&:close)
  end

  # Each kind of refusal is said: one does not hide another for 10 s.
  def test_each_refusal_is_said
    start_server
    s, s_id = login("s21")
    b, b_id = login("b21")
    send_env(s, { type: :challenge_accept, to: b_id })
    send_env(s, { type: :trade_decline, to: b_id, trade_id: "t" })
    sleep 0.3
    assert_equal 1, logs.count { |l| l.start_with?("server: account #{s_id} :challenge_accept with no invite") }
    assert_equal 1, logs.count { |l| l.start_with?("server: account #{s_id} :trade_decline with no invite") }
    [s, b].each(&:close)
  end

  def test_an_escrow_past_32_KiB_is_not_relayed
    start_server
    a, a_id = login("a19")
    b, b_id = login("b19")
    trade(a, a_id, b, b_id, "t19")
    send_env(a, { type: :trade_lock, to: b_id, trade_id: "t19", uid: 1 }, "x" * (40 * 1024))
    assert_empty types(b)
    send_env(a, { type: :trade_lock, to: b_id, trade_id: "t19", uid: 1 }, "x" * 1024)
    assert_equal [:trade_lock], types(b)
    [a, b].each(&:close)
  end

  def a_id_of(sock)
    @ids ||= {}
    @ids[sock]
  end

  # Off: the relay as before - a stranger's accept opens a session.
  def test_off_the_relay_is_as_before
    start_server({ "PEMK_RELAY_GUARD" => "off" })
    a, a_id = login("a13")
    b, b_id = login("b13")
    send_env(a, { type: :challenge_accept, to: b_id })
    assert_equal [:challenge_accept], types(b)
    send_env(a, { type: :battle_team, to: b_id }, "team")
    m = recv(b)
    assert_equal [:battle_team, "team"], [m[:env][:type], m[:body]]
    [a, b].each(&:close)
  end
end
